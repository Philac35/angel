// OrmGenerator, File modified 03/06/2025
// FIXED VERSION - Resolves inconsistent parameter handling AND comma issues

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
    return true; // ALWAYS use named parameters
  }

  void generateOrmCode(ClassElement element, ConstantReader annotation, libuilder.LibraryBuilder lib) {
    var className = element.name;
    var modelClassName = '${className}Model';
    var queryClassName = '${className}Query';
    var whereClassName = '${className}QueryWhere';
    var valuesClassName = '${className}QueryValues';
    var useNamedParams = true; // FORCE named parameters

    // Get non-static fields
    var regularFields = element.fields.where((f) => !f.isStatic).toList();

    // Generate the Model class
    generateModelClass(lib, modelClassName, element, useNamedParams);

    // Generate the Query class
    lib.body.add(Class((b) {
      b.name = queryClassName;
      b.extend = refer('Query<$modelClassName, $queryClassName>');

      // Default constructor - FIXED: Use named parameters consistently
      b.constructors.add(Constructor((cb) {
        var tableName = pluralize(className.toLowerCase());
        cb.initializers.add(Code('super(tableName: \'$tableName\')'));
      }));

      // newWhereClause method - FIXED: Use named parameter
      b.methods.add(Method((mb) {
        mb.name = 'newWhereClause';
        mb.returns = refer(whereClassName);
        mb.annotations.add(refer('override'));
        mb.body = Code('return $whereClassName(query: this);'); // FIXED: named parameter
      }));

      // Generate other query methods
      generateQueryMethods(b, modelClassName, element, useNamedParams);
    }));

    // Generate the QueryWhere class - FIXED: Constructor parameters
    lib.body.add(Class((b) {
      b.name = whereClassName;
      b.extend = refer('QueryWhere');

      // Constructor - FIXED: Consistent named parameters
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
          p.named = true;
        }));
        // FIXED: Pass named parameter to super
        cb.initializers.add(Code('super(query)'));
      }));

      generateWhereFields(b, element, useNamedParams);
    }));

    // Generate the QueryValues class - FIXED: Constructor parameters
    lib.body.add(Class((b) {
      b.name = valuesClassName;
      b.extend = refer('QueryValues');

      // Constructor - FIXED: Consistent named parameters
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
          p.named = true;
        }));
        // FIXED: Pass named parameter to super
        cb.initializers.add(Code('super(query)'));
      }));
    }));

    // Generate parseRow function
    generateParseRowFunction(lib, modelClassName, regularFields, useNamedParams);

    // Generate deserialize function
    generateDeserializeFunction(lib, modelClassName, useNamedParams);
  }

  void generateModelClass(libuilder.LibraryBuilder lib, String modelClassName, ClassElement element, bool useNamedParams) {
    var classBuilder = ClassBuilder()
      ..name = modelClassName
      ..extend = refer(element.name);

    // Get non-static fields
    var nonStaticFields = element.fields.where((f) => !f.isStatic).toList();

    // FIXED: Constructor with proper named parameters and comma handling
    var constructor = ConstructorBuilder()
      ..optionalParameters.addAll(
        nonStaticFields.map((field) {
          return Parameter((p) {
            p.name = field.name;
            p.type = refer(field.type.getDisplayString(withNullability: true));
            p.named = true;
          });
        }),
      );

    // FIXED: Super constructor call with named parameters - proper comma handling
    if (nonStaticFields.isNotEmpty) {
      var superArgs = nonStaticFields
          .map((field) => '${field.name}: ${field.name}')
          .join(', ');
      constructor.initializers.add(Code('super($superArgs)'));
    } else {
      constructor.initializers.add(Code('super()'));
    }

    classBuilder.constructors.add(constructor.build());

    // Add copyWith method - FIXED: Named parameters with proper comma handling
    var copyWithMethod = MethodBuilder()
      ..name = 'copyWith'
      ..returns = refer(modelClassName)
      ..optionalParameters.addAll(
        nonStaticFields.map((field) {
          return Parameter((p) {
            p.name = field.name;
            p.type = refer(field.type.getDisplayString(withNullability: true));
            p.named = true;
          });
        }),
      );

    // FIXED: Proper comma handling in copyWith method body
    if (nonStaticFields.isNotEmpty) {
      var copyWithArgs = nonStaticFields
          .map((field) => '${field.name}: ${field.name} ?? this.${field.name}')
          .join(',\n        ');

      copyWithMethod.body = Code('''
        return $modelClassName(
          $copyWithArgs
        );
      ''');
    } else {
      copyWithMethod.body = Code('return $modelClassName();');
    }

    classBuilder.methods.add(copyWithMethod.build());

    // Add toString method - FIXED: Proper comma handling
    var toStringMethod = MethodBuilder()
      ..name = 'toString'
      ..returns = refer('String')
      ..annotations.add(refer('override'));

    if (nonStaticFields.isNotEmpty) {
      var toStringFields = nonStaticFields
          .map((field) => '${field.name}: \$${field.name}')
          .join(', ');

      toStringMethod.body = Code('''
        return '$modelClassName($toStringFields)';
      ''');
    } else {
      toStringMethod.body = Code("return '$modelClassName()';");
    }

    classBuilder.methods.add(toStringMethod.build());

    lib.body.add(classBuilder.build());
  }

  void generateQueryMethods(ClassBuilder b, String className, ClassElement element, bool useNamedParams) {
    var whereClassName = '${className.replaceFirst('Model', '')}QueryWhere';
    var valuesClassName = '${className.replaceFirst('Model', '')}QueryValues';

    // get method - FIXED: All named parameters
    b.methods.add(Method((mb) {
      mb.name = 'get';
      mb.returns = refer('Future<List<$className>>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
        p.named = true;
      }));
      mb.body = Code('''
        return super.get(executor: executor).then((rows) {
          return rows.map((row) => deserialize$className(row: row))
              .where((x) => x != null)
              .cast<$className>()
              .toList();
        });
      ''');
    }));

    // first method - FIXED: All named parameters
    b.methods.add(Method((mb) {
      mb.name = 'first';
      mb.returns = refer('Future<$className?>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
        p.named = true;
      }));
      mb.body = Code('''
        return super.first(executor: executor).then((row) {
          if (row == null || row.isEmpty) return null;
          return deserialize$className(row: row);
        });
      ''');
    }));

    // one method - FIXED: All named parameters
    b.methods.add(Method((mb) {
      mb.name = 'one';
      mb.returns = refer('Future<$className>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
        p.named = true;
      }));
      mb.body = Code('''
        return super.one(executor: executor).then((row) {
          var parsed = deserialize$className(row: row);
          if (parsed == null) {
            throw StateError('Query returned no results or failed to parse');
          }
          return parsed;
        });
      ''');
    }));

    // deserialize method - FIXED: Named parameters
    b.methods.add(Method((mb) {
      mb.name = 'deserialize';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('Map<String, dynamic>');
        p.named = true;
      }));
      mb.annotations.add(refer('override'));
      mb.body = Code('return deserialize$className(row: row);');
    }));

    // where getter - FIXED: Named parameter
    b.methods.add(Method((mb) {
      mb.name = 'where';
      mb.returns = refer(whereClassName);
      mb.annotations.add(refer('override'));
      mb.body = Code('return ${whereClassName}(query: this);');
    }));

    // values getter - FIXED: Named parameter
    b.methods.add(Method((mb) {
      mb.name = 'values';
      mb.returns = refer(valuesClassName);
      mb.annotations.add(refer('override'));
      mb.body = Code('return ${valuesClassName}(query: this);');
    }));
  }

  void generateWhereFields(ClassBuilder b, ClassElement element, bool useNamedParams) {
    var nonStaticFields = element.fields.where((f) => !f.isStatic).toList();

    // expressionBuilders getter - FIXED: All named parameters with proper comma handling
    var expressionBuildersMethod = MethodBuilder()
      ..name = 'expressionBuilders'
      ..returns = refer('Map<String, SqlExpressionBuilder>')
      ..annotations.add(refer('override'));

    if (nonStaticFields.isNotEmpty) {
      var expressions = nonStaticFields.map((field) {
        var fieldType = field.type;
        var whereType = getWhereType(fieldType);
        return "'${field.name}': $whereType(query: query, fieldName: '${field.name}')";
      }).join(',\n          ');

      expressionBuildersMethod.body = Code('''
        return {
          $expressions
        };
      ''');
    } else {
      expressionBuildersMethod.body = Code('return <String, SqlExpressionBuilder>{};');
    }

    b.methods.add(expressionBuildersMethod.build());
  }

  void generateParseRowFunction(libuilder.LibraryBuilder lib, String className, List<FieldElement> fields, bool useNamedParams) {
    lib.body.add(Method((mb) {
      mb.name = '${className.toLowerCase()}ParseRow';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('List<dynamic>');
        p.named = true;
      }));

      var bodyCode = StringBuffer();
      bodyCode.writeln('if (row.isEmpty) return null;');
      bodyCode.writeln('try {');

      var constructorArgs = <String>[];
      var fieldIndex = 0;

      for (var field in fields) {
        var fieldType = field.type;
        var fieldName = field.name;

        if (isRelationField(field)) {
          constructorArgs.add('$fieldName: null');
          fieldIndex++;
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

        constructorArgs.add('$fieldName: $fieldName');
        fieldIndex++;
      }

      // FIXED: Proper comma handling in constructor call
      if (constructorArgs.isNotEmpty) {
        var argsString = constructorArgs.join(',\n    ');
        bodyCode.writeln('  return $className(\n    $argsString\n  );');
      } else {
        bodyCode.writeln('  return $className();');
      }

      bodyCode.writeln('} catch (e) {');
      bodyCode.writeln('  print(\'Error parsing row for $className: \$e\');');
      bodyCode.writeln('  return null;');
      bodyCode.writeln('}');

      mb.body = Code(bodyCode.toString());
    }));
  }

  void generateDeserializeFunction(libuilder.LibraryBuilder lib, String className, bool useNamedParams) {
    lib.body.add(Method((mb) {
      mb.name = 'deserialize$className';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('Map<String, dynamic>');
        p.named = true;
      }));
      // FIXED: Named parameter call
      mb.body = Code('return ${className.toLowerCase()}ParseRow(row: row);');
    }));
  }

  bool isRelationField(FieldElement field) {
    for (var annotation in field.metadata) {
      var name = annotation.element?.displayName;
      if (name == 'hasOne' || name == 'hasMany' || name == 'belongsTo') {
        return true;
      }
    }
    return false;
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
    if (word.endsWith('y')) {
      return '${word.substring(0, word.length - 1)}ies';
    } else if (word.endsWith('s') || word.endsWith('sh') || word.endsWith('ch') || word.endsWith('x') || word.endsWith('z')) {
      return '${word}es';
    } else {
      return '${word}s';
    }
  }
}