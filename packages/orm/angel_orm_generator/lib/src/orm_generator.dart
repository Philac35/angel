//Orm_generator, File modified 02/06/2025
//Fixed version with proper null safety and parameter handling

import 'dart:async';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:angel3_model/angel3_model.dart';
import 'package:angel3_orm/angel3_orm.dart';
import 'package:angel3_serialize/angel3_serialize.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:inflection3/inflection3.dart';
import 'package:recase/recase.dart';
import 'package:source_gen/source_gen.dart';
import 'package:angel3_serialize_generator/angel3_serialize_generator.dart';

import 'package:code_builder/code_builder.dart' as libuilder;

import 'package:pub_semver/pub_semver.dart';
import 'orm_build_context.dart';

// New annotation to configure parameter style
class OrmParameterStyle {
  final bool useNamedParameters;
  const OrmParameterStyle({this.useNamedParameters = true});
}

// Alternative: you can also use this in build.yaml configuration
class OrmConfig {
  final bool useNamedParameters;
  const OrmConfig({this.useNamedParameters = true});
}

Builder ormBuilder(BuilderOptions options) {
  return SharedPartBuilder([
    Angel3OrmGenerator(options),
  ], 'angel3_orm');
}

class Angel3OrmGenerator extends GeneratorForAnnotation<Orm> {
  static final RegExp _startWithUnderscore = RegExp(r'^_+');
  final BuilderOptions builderOptions;

  Angel3OrmGenerator([this.builderOptions = const BuilderOptions({})]);

  @override
  Future<String> generateForAnnotatedElement(
      Element element,
      ConstantReader annotation,
      BuildStep buildStep,
      ) async {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@Orm() can only be applied to classes.',
        element: element,
      );
    }

    var lib = Library((b) {
      try {
        generateOrmCode(element, annotation, b);
      } catch (e, st) {
        print('Error generating ORM code for ${element.name}: $e');
        print('Stack trace: $st');
        rethrow;
      }
    });

    var buf = StringBuffer();
    var emitter = DartEmitter();
    lib.accept(emitter, buf);

    try {
      return DartFormatter(languageVersion: Version.parse('3.7.2')).format(buf.toString());
    } catch (e) {
      print('Failed to format generated code:');
      print(buf.toString());
      rethrow;
    }
  }

  bool shouldUseNamedParameters(ClassElement element) {
    // 1. Check for @OrmParameterStyle annotation on the class
    for (var annotation in element.metadata) {
      if (annotation.element?.displayName == 'OrmParameterStyle') {
        try {
          var reader = ConstantReader(annotation.computeConstantValue());
          var useNamed = reader.read('useNamedParameters').boolValue;
          return useNamed;
        } catch (e) {
          // If we can't read the annotation, continue to other checks
        }
      }
    }

    // 2. Check build.yaml configuration
    var config = builderOptions.config;
    if (config.containsKey('use_named_parameters')) {
      return config['use_named_parameters'] as bool? ?? true;
    }

    // 3. Default to named parameters
    return true;
  }

  void generateOrmCode(ClassElement element, ConstantReader annotation, libuilder.LibraryBuilder lib) {
    var className = element.name;
    var queryClassName = '${className}Query';
    var whereClassName = '${className}QueryWhere';
    var valuesClassName = '${className}QueryValues';
    var useNamedParams = shouldUseNamedParameters(element);

    // Generate the Query class
    lib.body.add(Class((b) {
      b.name = queryClassName;
      b.extend = refer('Query<$className, $queryClassName>');

      // Constructor with configurable parameter style
      b.constructors.add(Constructor((cb) {
        if (useNamedParams) {
          // Generate named parameters for fields
          for (var field in element.fields) {
            if (field.isStatic) continue;

            cb.optionalParameters.add(Parameter((p) {
              p.name = field.name;
              p.type = refer('${field.type.getDisplayString(withNullability: true)}?');
              p.named = true;
            }));
          }
        } else {
          // Generate positional parameters for fields
          for (var field in element.fields) {
            if (field.isStatic) continue;

            cb.optionalParameters.add(Parameter((p) {
              p.name = field.name;
              p.type = refer('${field.type.getDisplayString(withNullability: true)}?');
              p.named = false;
            }));
          }
        }

        // Call to super constructor with proper field references
        var fieldReferences = element.fields
            .where((f) => !f.isStatic)
            .map((f) => '\'${f.name}\'')
            .join(', ');
        cb.initializers.add(Code('super(tableName: \'${pluralize(className.toLowerCase())}\', fields: [$fieldReferences])'));
      }));

      // newWhereClause method - with configurable parameter style
      b.methods.add(Method((mb) {
        mb.name = 'newWhereClause';
        mb.returns = refer(whereClassName);
        mb.annotations.add(refer('override'));
        if (useNamedParams) {
          mb.body = Code('return $whereClassName(query: this);');
        } else {
          mb.body = Code('return $whereClassName(this);');
        }
      }));

      // Generate other query methods
      generateQueryMethods(b, className, element, useNamedParams);
    }));

    // Generate the QueryWhere class
    lib.body.add(Class((b) {
      b.name = whereClassName;
      b.extend = refer('QueryWhere');

      // Constructor with configurable parameter style
      b.constructors.add(Constructor((cb) {
        if (useNamedParams) {
          cb.requiredParameters.add(Parameter((p) {
            p.name = 'query';
            p.type = refer(queryClassName);
            p.named = false; // This should not be named for the super call to work
          }));
        } else {
          cb.requiredParameters.add(Parameter((p) {
            p.name = 'query';
            p.type = refer(queryClassName);
            p.named = false;
          }));
        }
        cb.initializers.add(refer('super').call([refer('query')]).code);
      }));

      generateWhereFields(b, element, useNamedParams);
    }));

    // Generate parseRow method as a standalone function
    lib.body.add(Method((mb) {
      mb.name = '${className.toLowerCase()}ParseRow';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('List<dynamic>');
      }));

      var bodyCode = StringBuffer();
      bodyCode.writeln('if (row.isEmpty) return null;');
      bodyCode.writeln('try {');

      // Generate field parsing logic
      var fieldIndex = 0;
      var constructorParams = <String>[];

      for (var field in element.fields) {
        if (field.isStatic) continue;

        var fieldType = field.type;
        var fieldName = field.name;

        if (isRelationField(field)) {
          // Skip relation fields for now - they need special handling
          continue;
        }

        if (fieldType.isDartCoreString) {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex ? row[$fieldIndex] as String? : null;');
        } else if (fieldType.isDartCoreInt) {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex ? row[$fieldIndex] as int? : null;');
        } else if (fieldType.isDartCoreDouble) {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex ? row[$fieldIndex] as double? : null;');
        } else if (fieldType.isDartCoreBool) {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex ? row[$fieldIndex] as bool? : null;');
        } else if (fieldType.element?.name == 'DateTime') {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex && row[$fieldIndex] != null ? DateTime.parse(row[$fieldIndex].toString()) : null;');
        } else {
          bodyCode.writeln('  var $fieldName = row.length > $fieldIndex ? row[$fieldIndex] : null;');
        }

        constructorParams.add('$fieldName: $fieldName');
        fieldIndex++;
      }

      bodyCode.writeln('  return $className(${constructorParams.join(', ')});');
      bodyCode.writeln('} catch (e) {');
      bodyCode.writeln('  print(\'Error parsing row for $className: \$e\');');
      bodyCode.writeln('  return null;');
      bodyCode.writeln('}');

      mb.body = Code(bodyCode.toString());
    }));

    // Generate deserialize method for the Query class
    lib.body.add(Method((mb) {
      mb.name = 'deserialize${className}';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('List<dynamic>');
      }));
      mb.body = Code('return ${className.toLowerCase()}ParseRow(row);');
    }));
  }

  void generateQueryMethods(ClassBuilder b, String className, ClassElement element, bool useNamedParams) {
    // get method
    b.methods.add(Method((mb) {
      mb.name = 'get';
      mb.returns = refer('Future<List<$className>>');
      if (useNamedParams) {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = false; // Keep this positional for compatibility
        }));
      } else {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = false;
        }));
      }
      mb.body = Code('''
        return super.get(executor).then((rows) {
          return rows.map((row) => deserialize${className}(row)).where((x) => x != null).cast<$className>().toList();
        });
      ''');
    }));

    // first method
    b.methods.add(Method((mb) {
      mb.name = 'first';
      mb.returns = refer('Future<$className?>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
        p.named = false;
      }));
      mb.body = Code('''
        return super.first(executor).then((row) {
          if (row == null || row.isEmpty) return null;
          return deserialize${className}(row);
        });
      ''');
    }));

    // one method
    b.methods.add(Method((mb) {
      mb.name = 'one';
      mb.returns = refer('Future<$className>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
        p.named = false;
      }));
      mb.body = Code('''
        return super.one(executor).then((row) {
          var parsed = deserialize${className}(row);
          if (parsed == null) {
            throw StateError('Query returned no results or failed to parse');
          }
          return parsed;
        });
      ''');
    }));
  }

  void generateWhereFields(ClassBuilder b, ClassElement element, bool useNamedParams) {
    for (var field in element.fields) {
      if (field.isStatic) continue;

      var fieldName = field.name;
      var dartType = field.type;

      if (isRelationField(field)) {
        // Handle relation fields
        var relatedClass = getRelatedClassName(field);
        if (relatedClass != null) {
          b.methods.add(Method((mb) {
            mb.name = fieldName;
            mb.returns = refer('${relatedClass}QueryWhere');
            if (useNamedParams) {
              mb.body = Code('return ${relatedClass}QueryWhere(${relatedClass}Query());');
            } else {
              mb.body = Code('return ${relatedClass}QueryWhere(${relatedClass}Query());');
            }
          }));
        }
      } else {
        // Handle regular fields
        var whereType = getWhereType(dartType);
        b.methods.add(Method((mb) {
          mb.name = fieldName;
          mb.returns = refer(whereType);
          mb.body = Code('return ${whereType}(\'$fieldName\');');
        }));
      }
    }
  }

  bool isRelationField(FieldElement field) {
    // Check if field has @hasOne, @hasMany, @belongsTo annotations
    for (var annotation in field.metadata) {
      var name = annotation.element?.displayName;
      if (name == 'hasOne' || name == 'hasMany' || name == 'belongsTo') {
        return true;
      }
    }
    return false;
  }

  String? getRelatedClassName(FieldElement field) {
    var type = field.type;

    if (type.isDartCoreList) {
      // For List<SomeClass>, extract SomeClass
      if (type is ParameterizedType && type.typeArguments.isNotEmpty) {
        var argType = type.typeArguments.first;
        if (argType.element is ClassElement) {
          return argType.element!.name;
        }
      }
    } else if (type.element is ClassElement) {
      // For direct class references
      return type.element!.name;
    }

    return null;
  }

  int getRelationFieldCount(FieldElement field) {
    // This would typically be determined by analyzing the related model
    // For now, return a default count
    return 3; // Assuming id, created_at, updated_at as minimum
  }

  String getWhereType(DartType type) {
    if (type.isDartCoreString) {
      return 'StringSqlExpressionBuilder';
    } else if (type.isDartCoreInt) {
      return 'NumericSqlExpressionBuilder<int>';
    } else if (type.isDartCoreDouble) {
      return 'NumericSqlExpressionBuilder<double>';
    } else if (type.isDartCoreBool) {
      return 'BooleanSqlExpressionBuilder';
    } else if (type.element?.name == 'DateTime' && type.element?.library?.name == 'dart.core') {
      return 'DateTimeSqlExpressionBuilder';
    } else {
      return 'SqlExpressionBuilder';
    }
  }

  String pluralize(String word) {
    // Simple pluralization - you might want to use the inflection3 package here
    return '${word}s';
  }
}