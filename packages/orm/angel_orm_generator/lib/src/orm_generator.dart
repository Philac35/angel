// OrmGenerator, File modified 03/06/2025
// FIXED VERSION - Resolves parameter handling, method signatures, and parent class compatibility
// ADDITIONAL FIXES: Added missing deserialize functions and resolved naming conflicts

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

  void generateOrmCode(ClassElement element, ConstantReader annotation, libuilder.LibraryBuilder lib) {
    var className = element.name;
    var modelClassName = '${className}Model';
    var queryClassName = '${className}Query';
    var whereClassName = '${className}QueryWhere';
    var valuesClassName = '${className}QueryValues';

    // Get non-static fields
    var regularFields = element.fields.where((f) => !f.isStatic).toList();
    var fieldNames = regularFields.map((f) => f.name).toList();
    var tableName = pluralize(className.toLowerCase());

    // Generate the Model class (for serialization compatibility)
    // FIXED: Use different name to avoid conflict with Angel3 serializer
    generateModelClass(lib, modelClassName, element);

    // Generate the Query class
    lib.body.add(Class((b) {
      b.name = queryClassName;
      b.extend = refer('Query<$modelClassName, $whereClassName>');

      // Constructor - FIXED: Call super() without parameters
      b.constructors.add(Constructor((cb) {
        cb.initializers.add(Code('super()'));
      }));

      // newWhereClause method
      b.methods.add(Method((mb) {
        mb.name = 'newWhereClause';
        mb.returns = refer(whereClassName);
        mb.annotations.add(refer('override'));
        mb.body = Code('return $whereClassName(this);');
      }));

      // Generate query methods with correct signatures
      generateQueryMethods(b, modelClassName, element, fieldNames, tableName);
    }));

    // Generate the QueryValues class
    lib.body.add(Class((b) {
      b.name = valuesClassName;
      b.extend = refer('QueryValues');

      // Add the field query - FIXED: Keep as nullable (late workaround)
      b.fields.add(Field((fb) {
        fb.name = 'query';
        fb.type = refer('$queryClassName?');
        fb.modifier = FieldModifier.var$;
      }));

      // Add all Fields needed in toMap
      for (final field in regularFields) {
        b.fields.add(Field((fb) {
          fb.name = field.name;
          fb.type = refer(field.type.getDisplayString(withNullability: true));
        }));
      }



      // Constructor - FIXED: Assign to nullable field manually
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
        }));
        cb.initializers.add(Code('this.query = query'));
      }));

      // toMap method
      b.methods.add(Method((mb) {
        mb.name = 'toMap';
        mb.returns = refer('Map<String, dynamic>');
        mb.annotations.add(refer('override'));
        mb.body = Code('''
          return {
            ${regularFields.map((f) => "'${f.name}': ${f.name}").join(',\n')}
          };
        ''');
      }));


      //Function
      b.methods.add(Method((mb) {
        mb.name = 'where_';
        mb.returns = refer('${className}QueryWhere');
        mb.annotations.add(refer('override'));
        mb.body = Code('return ${className}QueryWhere(query!);');
      }));

      b.methods.add(Method((mb) {
        mb.name = 'values_';
        mb.returns = refer('${className}QueryValues');
        mb.annotations.add(refer('override'));
        mb.body = Code('return ${className}QueryValues(query!);');
      }));

      // Add values getter of previous functions
      b.methods.add(Method((method) {
        method
          ..name = 'values'
          ..returns = refer('${className}QueryValues')
          ..type = MethodType.getter
          ..body = Code('return values_();');
      }));

      // Add where getter
      b.methods.add(Method((method) {
        method
          ..name = 'where'
          ..returns = refer('${className}QueryWhere')
          ..type = MethodType.getter
          ..body = Code('return where_();');
      }));

    }));



    // Generate the QueryWhere class
    lib.body.add(Class((b) {
      b.name = whereClassName;
      b.extend = refer('QueryWhere');

      // Add the field
      b.fields.add(Field((fb) {
        fb.name = 'query';
        fb.type = refer(queryClassName);
        fb.modifier = FieldModifier.var$;
      }));

      // Constructor - FIXED: Use positional parameter
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
        }));
        cb.initializers.add(Code('this.query = query'));
      }));

      b.methods.add(Method((mb) {
        mb.name = 'where';
        mb.returns = refer('${className}QueryWhere');
        mb.annotations.add(refer('override'));
        mb.body = Code('return ${className}QueryWhere(query);');
      }));

      b.methods.add(Method((mb) {
        mb.name = 'values';
        mb.returns = refer('${className}QueryValues');
        mb.annotations.add(refer('override'));
        mb.body = Code('return ${className}QueryValues(query);');
      }));

      // Generate where fields
      generateWhereFields(b, element);
    }));

    // FIXED: Generate missing parseRow and deserialize functions
    generateParseRowFunction(lib, modelClassName, regularFields);
    generateDeserializeFunction(lib, modelClassName);
  }

  void generateModelClass(libuilder.LibraryBuilder lib, String modelClassName, ClassElement element) {
    var classBuilder = ClassBuilder()
      ..name = modelClassName
      ..extend = refer(element.name);

    // Get non-static fields
    var nonStaticFields = element.fields.where((f) => !f.isStatic).toList();

    // Constructor - FIXED: Use named parameters to match parent class
    var constructor = ConstructorBuilder();

    // Add named parameters
    constructor.optionalParameters.addAll(
      nonStaticFields.map((field) {
        return Parameter((p) {
          p.name = field.name;
          p.type = refer(field.type.getDisplayString(withNullability: true));
          p.named = true;
        });
      }),
    );

    // Super constructor call with named parameters
    if (nonStaticFields.isNotEmpty) {
      var superArgs = nonStaticFields
          .map((field) => '${field.name}: ${field.name}')
          .join(', ');
      constructor.initializers.add(Code('super($superArgs)'));
    } else {
      constructor.initializers.add(Code('super()'));
    }

    classBuilder.constructors.add(constructor.build());

    // Add copyWith method with named parameters
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

    if (nonStaticFields.isNotEmpty) {
      var copyWithArgs = nonStaticFields
          .map((field) => '${field.name}: ${field.name} ?? this.${field.name}')
          .join(', ');

      copyWithMethod.body = Code('return $modelClassName($copyWithArgs);');
    } else {
      copyWithMethod.body = Code('return $modelClassName();');
    }

    classBuilder.methods.add(copyWithMethod.build());


    // Add toJson method to the model class
      var  toJsonMethod= MethodBuilder()
          ..name = 'toJson'
          ..returns = refer('Map<String, dynamic>')
          ..body = Code('return ${modelClassName}Serializer.toMap(this);');




    // Add toString method
    var toStringMethod = MethodBuilder()
      ..name = 'toString'
      ..returns = refer('String')
      ..annotations.add(refer('override'));

    if (nonStaticFields.isNotEmpty) {
      var toStringFields = nonStaticFields
          .map((field) => '${field.name}: \$${field.name}')
          .join(', ');

      toStringMethod.body = Code("return '$modelClassName($toStringFields)';");
    } else {
      toStringMethod.body = Code("return '$modelClassName()';");
    }

    classBuilder.methods.add(toStringMethod.build());

    lib.body.add(classBuilder.build());
  }




  void generateQueryMethods(ClassBuilder b, String className, ClassElement element,
      List<String> fieldNames, String tableNameStr) {
    var whereClassName = '${className.replaceFirst('Model', '')}QueryWhere';
    var valuesClassName = '${className.replaceFirst('Model', '')}QueryValues';

    // get method - FIXED: Use positional parameter for executor
    b.methods.add(Method((mb) {
      mb.name = 'get';
      mb.returns = refer('Future<List<$className>>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
      }));
      mb.body = Code('''
        return super.get(executor).then((rows) {
          return rows.map((row) => deserialize$className(row))
              .where((x) => x != null)
              .cast<$className>()
              .toList();
        });
      ''');
    }));

    // getOne method instead of first/one to avoid conflicts
    b.methods.add(Method((mb) {
      mb.name = 'getOne';
      mb.returns = refer('Future<Optional<$className>>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'executor';
        p.type = refer('QueryExecutor');
      }));
      mb.body = Code('''
        return super.get(executor).then((rows) {
          if (rows.isEmpty) return Optional.empty();
          final model = deserialize$className(rows.first as List<dynamic>);
          if (model == null) {
            throw Exception('Deserialization returned null for valid row');
          }
          return Optional.of(model);
        });
      ''');
    }));

    // deserialize method - FIXED: Use List<dynamic> parameter type
    b.methods.add(Method((mb) {
      mb.name = 'deserialize';
      mb.returns = refer('Optional<$className>');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('List<dynamic>');
      }));
      mb.annotations.add(refer('override'));
      mb.body = Code('return Optional.ofNullable(${className.toLowerCase()}ParseRow(row));');
    }));

    // FIXED: Use getters instead of methods to avoid conflicts
    b.methods.add(Method((mb) {
      mb.name = 'where_';
      mb.returns = refer(whereClassName);
      mb.body = Code('return ${whereClassName}(this);');
    }));

    b.methods.add(Method((mb) {
      mb.name = 'values_';
      mb.returns = refer(valuesClassName);
      mb.body = Code('return ${valuesClassName}(this);');
    }));

    // fields getter
    b.methods.add(Method((mb) {
      mb.name = 'fields';
      mb.returns = refer('List<String>');
      mb.type = MethodType.getter;
      mb.annotations.add(refer('override'));
      mb.body = Code("return [${fieldNames.map((f) => "'$f'").join(', ')}];");
    }));

    // tableName getter
    b.methods.add(Method((mb) {
      mb.name = 'tableName';
      mb.returns = refer('String');
      mb.type = MethodType.getter;
      mb.annotations.add(refer('override'));
      mb.body = Code("return '$tableNameStr';");
    }));
  }

  void generateWhereFields(ClassBuilder b, ClassElement element) {
    var nonStaticFields = element.fields.where((f) => !f.isStatic).toList();

    // Add field declarations
    for (final field in nonStaticFields) {
      b.fields.add(Field((fb) {
        fb.name = field.name;
        fb.type = refer(field.type.getDisplayString(withNullability: true));
        fb.modifier = FieldModifier.var$;
      }));
    }

    String? getWhereType(DartType fieldType) {
      if (fieldType.isDartCoreInt) {
        return 'NumericSqlExpressionBuilder<int>';
      }
      if (fieldType.isDartCoreDouble) {
        return 'NumericSqlExpressionBuilder<double>';
      }
      if (fieldType.isDartCoreNum) {
        return 'NumericSqlExpressionBuilder<num>';
      }
      if (fieldType.isDartCoreString) {
        return 'StringSqlExpressionBuilder';
      }
      if (fieldType.isDartCoreBool) {
        return 'BoolSqlExpressionBuilder';
      }
      if (fieldType.getDisplayString(withNullability: false) == 'DateTime') {
        return 'DateTimeSqlExpressionBuilder';
      }

      // Check if this is a relation field (foreign key)
      var fieldElement = nonStaticFields.firstWhere((f) => f.type == fieldType, orElse: () => throw StateError('Field not found'));
      if (isRelationField(fieldElement)) {
        // For relation fields, skip them or use a generic builder
        return null; // We'll handle this in the expressions generation
      }

      return 'SqlExpressionBuilder'; // Fallback for unknown types
    }

    // FIXED: Use getter instead of method to avoid conflicts
    var expressionBuildersGetter = MethodBuilder()
      ..name = 'expressionBuilders'
      ..returns = refer('Iterable<SqlExpressionBuilder>')
      ..type = MethodType.getter
      ..annotations.add(refer('override'));

    if (nonStaticFields.isNotEmpty) {
      var expressions = <String>[];

      for (var field in nonStaticFields) {
        var fieldType = field.type;

        // Skip relation fields to avoid "Abstract classes can't be instantiated" error
        if (isRelationField(field)) {
          continue;
        }

        var whereType = getWhereType(fieldType);
        if (whereType != null) {
          expressions.add("$whereType(query, '${field.name}')");
        }
      }

      if (expressions.isNotEmpty) {
        var expressionsString = expressions.join(',\n    ');
        expressionBuildersGetter.body = Code('''
    return [
      $expressionsString
    ];
  ''');
      } else {
        expressionBuildersGetter.body = Code('return const [];');
      }
    } else {
      expressionBuildersGetter.body = Code('return const [];');
    }

    b.methods.add(expressionBuildersGetter.build());
  }

  // Helper function related to isRelationField
  bool isRelationField(FieldElement field) {
    for (var annotation in field.metadata) {
      var name = annotation.element?.displayName;
      if (name == 'hasOne' || name == 'hasMany' || name == 'belongsTo') {
        return true;
      }
    }
    return false;
  }

  // FIXED: Generate parseRow function (moved from inside generateWhereFields)
  void generateParseRowFunction(libuilder.LibraryBuilder lib, String className, List<FieldElement> fields) {
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

      var constructorArgs = <String>[];
      var fieldIndex = 0;

      for (var field in fields) {
        var fieldType = field.type;
        var fieldName = field.name;

        if (isRelationField(field)) {
          // Skip relation fields in parsing
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

      // FIXED: Use named parameters for constructor to match Model class
      if (constructorArgs.isNotEmpty) {
        var argsString = constructorArgs.join(', ');
        bodyCode.writeln('  return $className($argsString);');
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

  // FIXED: Generate deserialize function (moved from inside generateWhereFields)
  void generateDeserializeFunction(libuilder.LibraryBuilder lib, String className) {
    lib.body.add(Method((mb) {
      mb.name = 'deserialize$className';
      mb.returns = refer('$className?');
      mb.requiredParameters.add(Parameter((p) {
        p.name = 'row';
        p.type = refer('List<dynamic>');
      }));
      mb.body = Code('return ${className.toLowerCase()}ParseRow(row);');
    }));
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