

//Orm_generator, File modified 28/05/2025 10h58
//It manages only named parameters



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

      return DartFormatter(languageVersion: Version.parse ('3.7.2') ).format(buf.toString());
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

  void generateOrmCode(ClassElement element, ConstantReader annotation,libuilder.LibraryBuilder lib) {
    var className = element.name;
    var queryClassName = '${className}Query';
    var whereClassName = '${className}QueryWhere';
    var valuesClassName = '${className}QueryValues';
    var useNamedParams = shouldUseNamedParameters(element);

    // Generate the Query class
    lib.body.add(Class((b) {
      b.name = queryClassName;
      b.extend = refer('Query<$className, ${queryClassName}>');

      // Constructor with configurable parameter style
      b.constructors.add(Constructor((b) {
        if (useNamedParams) {
          // Generate named parameters
          for (var field in element.fields) {
            if (field.isStatic) continue;

          b.optionalParameters.add(Parameter((p) {
            p.name = field.name;//'query';
            p.type = refer(field.type.getDisplayString(withNullability: true)); // refer('Query?');
            p.named = true;}
          ));}
        } else {

          // Generate positional parameters
          for (var field in element.fields) {
            if (field.isStatic) continue;

            b.optionalParameters.add(Parameter((p) {
            p.name = 'query';
            p.type = refer(field.type.getDisplayString(withNullability: true));//refer('Query?');
          //  p.named = false;
          }));
        }}
        // Call to super constructor
        var superParams = element.fields.where((f) => !f.isStatic).map((f) => refer('Reference').call([refer(f.name)]).code).toList();
        b.initializers.add(Code('super(${superParams.join(', ')})')); // b.initializers.add(refer('super').call([refer('query')]).code);


      }));

      // newWhereClause method - with configurable parameter style
      b.methods.add(Method((b) {
        b.name = 'newWhereClause';
        b.returns = refer(whereClassName);
        b.annotations.add(refer('override'));
        if (useNamedParams) {
          b.body = Code('return ${whereClassName}(query: this);');
        } else {
          b.body = Code('return ${whereClassName}(this);');
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
      b.constructors.add(Constructor((b) {
        if (useNamedParams) {
          b.requiredParameters.add(Parameter((p) {
            p.name = 'query';
            p.type = refer(queryClassName);
            p.named = true;
            p.required = true;
          }));
        } else {
          b.requiredParameters.add(Parameter((p) {
            p.name = 'query';
            p.type = refer(queryClassName);
            p.named = false;
          }));
        }
        b.initializers.add(refer('super').call([refer('query')]).code);
      }));

      generateWhereFields(b, element, useNamedParams);
    }));

    // Generate parseRow method
    lib.body.add(Method((b) {
      b.name = 'parseRow';
      b.returns = refer('Optional<$className>');
      if (useNamedParams) {
        b.requiredParameters.add(Parameter((p) {
          p.name = 'row';
          p.type = refer('List');
          p.named = true;
         // p.required = true;
        }));
      } else {
        b.requiredParameters.add(Parameter((p) {
          p.name = 'row';
          p.type = refer('List');
         // p.named = false;
        }));
      }

      var bodyCode = StringBuffer();
      bodyCode.writeln('if (row.isEmpty) return Optional.empty();');

      var fieldIndex = 0;
      var relationIndex = 0;

      for (var field in element.fields) {
        if (field.isStatic) continue;

        var fieldType = field.type;
        var isRelation = isRelationField(field);

        if (isRelation) {
          var relatedClassName = getRelatedClassName(field);
          if (relatedClassName != null) {
            bodyCode.writeln('if (row.length > $relationIndex) {');
            if (useNamedParams) {
              bodyCode.writeln('  var modelOpt = ${relatedClassName}Query().parseRow(row: row.skip($relationIndex).take(${getRelationFieldCount(field)}).toList());');
            } else {
              bodyCode.writeln('  var modelOpt = ${relatedClassName}Query().parseRow(row.skip($relationIndex).take(${getRelationFieldCount(field)}).toList());');
            }
            bodyCode.writeln('  // Handle relation assignment');
            bodyCode.writeln('}');
            relationIndex += getRelationFieldCount(field);
          }
        }
        fieldIndex++;
      }

      bodyCode.writeln('return Optional.of($className());'); // Simplified for now

      b.body = Code(bodyCode.toString());
    }));

    // Generate deserialize method
    lib.body.add(Method((b) {
      b.name = 'deserialize';
      b.returns = refer('Optional<$className>');
      b.annotations.add(refer('override'));
      if (useNamedParams) {
        b.optionalParameters.add(Parameter((p) {
          p.name = 'row';
          p.type = refer('List');
         // p.named = true;
          p.required = true;
        }));
        b.body = Code('return parseRow(row: row);');
      } else {
        b.requiredParameters.add(Parameter((p) {
          p.name = 'row';
          p.type = refer('List');
         // p.named = false;
        }));
        b.body = Code('return parseRow(row);');
      }
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
          p.named = true;
        //  p.required = true;
        }));
      } else {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = false;
        }));
      }
      mb.body = Code('''
        return super.get(executor).then((result) {
          return result.map((row) => ${useNamedParams ? 'deserialize(row: row)' : 'deserialize(row)'}).where((x) => x.isPresent).map((x) => x.value).toList();
        });
      ''');
    }));

    // first method
    b.methods.add(Method((mb) {
      mb.name = 'first';
      mb.returns = refer('Future<$className?>');
      if (useNamedParams) {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = true;
         // p.required = true;
        }));
      } else {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = false;
        }));
      }
      mb.body = Code('''
        return super.first(executor).then((result) {
          if (result.isEmpty) return null;
          var parsed = ${useNamedParams ? 'deserialize(row: result)' : 'deserialize(result)'};
          return parsed.isPresent ? parsed.value : null;
        });
      ''');
    }));

    // one method
    b.methods.add(Method((mb) {
      mb.name = 'one';
      mb.returns = refer('Future<$className>');
      if (useNamedParams) {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = true;
        //  p.required = true;
        }));
      } else {
        mb.requiredParameters.add(Parameter((p) {
          p.name = 'executor';
          p.type = refer('QueryExecutor');
          p.named = false;
        }));
      }
      mb.body = Code('''
        return super.one(executor).then((result) {
          var parsed = ${useNamedParams ? 'deserialize(row: result)' : 'deserialize(result)'};
          if (!parsed.isPresent) {
            throw StateError('Query returned no results');
          }
          return parsed.value;
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
              mb.body = Code('return ${relatedClass}QueryWhere(query: query);');
            } else {
              mb.body = Code('return ${relatedClass}QueryWhere(query);');
            }
          }));
        }
      } else {
        // Handle regular fields
        var whereType = getWhereType(dartType);
        b.methods.add(Method((mb) {
          mb.name = fieldName;
          mb.returns = refer(whereType);
          if (useNamedParams) {
            mb.body = Code('return ${whereType}(query: query, fieldName: \'$fieldName\');');
          } else {
            mb.body = Code('return ${whereType}(query, \'$fieldName\');');
          }
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
          return argType.element!.name!;
        }
      }
    } else if (type.element is ClassElement) {
      // For direct class references
      return type.element!.name!;
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

}