// OrmGenerator, File modified 03/06/2025
// FIXED VERSION - Resolves parameter handling, method signatures, and parent class compatibility

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
    generateModelClass(lib, modelClassName, element);

    // Generate the Query class
    lib.body.add(Class((b) {
      b.name = queryClassName;
      b.extend = refer('Query<$modelClassName, $whereClassName>');

      // Constructor - FIXED: Use named parameter for tableName
      b.constructors.add(Constructor((cb) {
        cb.initializers.add(Code('super(tableName: \'$tableName\')'));
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

    // Generate the QueryWhere class
    lib.body.add(Class((b) {
      b.name = whereClassName;
      b.extend = refer('QueryWhere');


      // Add the field
      b.fields.add(Field((fb) {
        fb.name = 'query';
        fb.type = refer(queryClassName);
        // If you want it to be final (recommended)
        fb.modifier = FieldModifier.var$;
      }));


      // Constructor - FIXED: Use positional parameter
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
        }));
        // Assign to the field
        cb.initializers.add(Code('this.query = query'));
        // Also call super or not cause parent class doesn't have query field
        // cb.initializers.add(Code('super(query)'));
      }));

      b.methods.add(Method((mb) {
        mb.name = 'where';
        mb.returns = refer('${className}QueryWhere');
        mb.annotations.add(refer('override'));
        mb.body = Code('''
          return where_();''');
      }));

      b.methods.add(Method((mb) {
        mb.name = 'value';
        mb.returns = refer('${className}QueryValue');
        mb.annotations.add(refer('override'));
        mb.body = Code('''
          return value_();''');
      }));

      // Generate where fields
      generateWhereFields(b, element);
    }));

    // Generate the QueryValues class
    lib.body.add(Class((b) {
      b.name = valuesClassName;
      b.extend = refer('QueryValues');

      // Add the field
      b.fields.add(Field((fb) {
        fb.name = 'query';
        fb.type = refer(queryClassName);
        // If you want it to be final (recommended)
        fb.modifier = FieldModifier.var$;
      }));

      // Constructor - FIXED: Use positional parameter
      b.constructors.add(Constructor((cb) {
        cb.requiredParameters.add(Parameter((p) {
          p.name = 'query';
          p.type = refer(queryClassName);
        }));
       // cb.initializers.add(Code('super(query)')); There is no instance variable query in super class Query
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
    }));

    // Generate parseRow function
   // generateParseRowFunction(lib, modelClassName, regularFields);

    // Generate deserialize function
   // generateDeserializeFunction(lib, modelClassName);
  }

  void generateModelClass(libuilder.LibraryBuilder lib, String modelClassName, ClassElement element) {
    var classBuilder = ClassBuilder()
      ..name = modelClassName
      ..extend = refer(element.name);

    // Get non-static fields
    var nonStaticFields = element.fields.where((f) => !f.isStatic).toList();

    // Constructor - FIXED: Use named parameters
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
      mb.body = Code('return Optional.ofNullable( ${className.toLowerCase()}ParseRow(row));');
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

    String getWhereType(DartType fieldType) {
      // You may need to adjust the type checks depending on your analyzer version
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
      // Add more custom types as needed, e.g.:
      // if (fieldType.getDisplayString(withNullability: false) == 'YourCustomType') {
      //   return 'YourCustomSqlExpressionBuilder';
      // }
      return 'SqlExpressionBuilder'; // Fallback for unknown types
    }


    // FIXED: Use getter instead of method to avoid conflicts
    var expressionBuildersGetter = MethodBuilder()
      ..name = 'expressionBuilders'
      ..returns = refer('Iterable<SqlExpressionBuilder>')
      ..type = MethodType.getter
      ..annotations.add(refer('override'));

    if (nonStaticFields.isNotEmpty) {
      var expressions = nonStaticFields.map((field) {
        var fieldType = field.type;
        var whereType = getWhereType(fieldType); // e.g., NumericSqlExpressionBuilder<int>
        return "$whereType(query, '${field.name}')";
      }).join(',\n    ');

      expressionBuildersGetter.body = Code('''
    return [
      $expressions
    ];
  ''');
    } else {
      expressionBuildersGetter.body = Code('return const [];');
    }



    //Helper function related to isRelationField

    bool isRelationField(FieldElement field) {
      for (var annotation in field.metadata) {
        var name = annotation.element?.displayName;
        if (name == 'hasOne' || name == 'hasMany' || name == 'belongsTo') {
          return true;
        }
      }
      return false;
    }


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
          constructorArgs.add('null');
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

        constructorArgs.add('${fieldName}:${fieldName}' );
        fieldIndex++;
      }

      // Use -!positional- parameters for constructor
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

}