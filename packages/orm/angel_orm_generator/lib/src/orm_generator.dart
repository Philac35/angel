//Orm_generator, File modified 28/05/2025 10h58
//It manages only named parameters

import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:angel3_orm/angel3_orm.dart';
import 'package:angel3_serialize/angel3_serialize.dart';
import 'package:angel3_serialize_generator/angel3_serialize_generator.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart' hide LibraryBuilder;
import 'package:source_gen/source_gen.dart';

import 'orm_build_context.dart';

var floatTypes = [
  ColumnType.decimal,
  ColumnType.float,
  ColumnType.numeric,
  ColumnType.real,
  const ColumnType('double precision'),
];

/// ORM Builder
Builder ormBuilder(BuilderOptions options) {
  return SharedPartBuilder([
    OrmGenerator(
        autoSnakeCaseNames: options.config['auto_snake_case_names'] != false)
  ], 'angel3_orm');
}

TypeReference futureOf(String type) {
  return TypeReference((b) => b
    ..symbol = 'Future'
    ..types.add(refer(type)));
}

/// Generate `<Model>.g.dart` from an abstract `Model` class.
class OrmGenerator extends GeneratorForAnnotation<Orm> {
  final bool? autoSnakeCaseNames;

  OrmGenerator({this.autoSnakeCaseNames});

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element is ClassElement) {
      var ctx = await buildOrmContext({}, element, annotation, buildStep,
          buildStep.resolver, autoSnakeCaseNames);
      if (ctx == null) {
        throw 'Invalid ORM build context';
      }

      var lib = buildOrmLibrary(buildStep.inputId, ctx);

      return lib.accept(DartEmitter(useNullSafetySyntax: true)).toString();
    } else {
      throw 'The @Orm() annotation can only be applied to classes.';
    }
  }

  Library buildOrmLibrary(AssetId inputId, OrmBuildContext ctx) {
    return Library((lib) {
      // Create `FooQuery` class
      lib.body.add(buildQueryClass(ctx));

      // Create `FooQueryWhere` class
      lib.body.add(buildWhereClass(ctx));

      // Create `FooQueryValues` class
      lib.body.add(buildValuesClass(ctx));
    });
  }

  /// Generate <Model>Query class
  Class buildQueryClass(OrmBuildContext ctx) {
    return Class((clazz) {
      var rc = ctx.buildContext.modelClassNameRecase;
      var queryWhereType = refer('${rc.pascalCase}QueryWhere');
      log.info('Generating ${rc.pascalCase}QueryWhere');

      var nullableQueryWhereType = TypeReference((b) => b
        ..symbol = '${rc.pascalCase}QueryWhere'
        ..isNullable = true);

      clazz
        ..name = '${rc.pascalCase}Query'
        ..extend = TypeReference((b) {
          b
            ..symbol = 'Query'
            ..types.addAll([
              ctx.buildContext.modelClassType,
              queryWhereType,
            ]);
        });

      // Override casts so that we can cast doubles
      clazz.methods.add(Method((b) {
        b
          ..name = 'casts'
          ..annotations.add(refer('override'))
          ..returns = TypeReference((b) => b
            ..symbol = 'Map'
            ..types.add(refer('String'))
            ..types.add(refer('String')))
          ..type = MethodType.getter
          ..body = Block((b) {
            var args = <String, Expression>{};
            b.addExpression(literalMap(args).returned);
          });
      }));

      // Add newWhereClause method
      clazz.methods.add(Method((b) {
        b
          ..name = 'newWhereClause'
          ..annotations.add(refer('override'))
          ..returns = queryWhereType
          ..body = Block((b) => b.addExpression(queryWhereType.newInstance(
              [], {refer('query').toString(): refer('this')}).returned));
      }));

      // Add values
      clazz.fields.add(Field((b) {
        var type = refer('${rc.pascalCase}QueryValues');
        b
          ..name = 'values'
          ..modifier = FieldModifier.final$
          ..annotations.add(refer('override'))
          ..type = type
          ..assignment = type.newInstance([], {}).code;
      }));

      // Add tableName
      clazz.methods.add(Method((m) {
        m
          ..name = 'tableName'
          ..returns = refer('String')
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = Block((b) {
            b.addExpression(literalString(ctx.tableName!).returned);
          });
      }));

      // Add fields getter
      clazz.methods.add(Method((m) {
        m
          ..name = 'fields'
          ..returns = TypeReference((b) => b
            ..symbol = 'List'
            ..types.add(TypeReference((b) => b..symbol = 'String')))
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = Block((b) {
            var names = ctx.effectiveFields
                .map((f) =>
                    literalString(ctx.buildContext.resolveFieldName(f.name)!))
                .toList();
            b.addExpression(
                declareConst('_fields').assign(literalConstList(names)));
            b.addExpression(refer('_selectedFields')
                .property('isEmpty')
                .conditional(
                  refer('_fields'),
                  refer('_fields')
                      .property('where')
                      .call([
                        CodeExpression(
                            Code('(field) => _selectedFields.contains(field)'))
                      ])
                      .property('toList')
                      .call([]),
                )
                .returned);
          });
      }));

      // Add _selectedFields member
      clazz.fields.add(Field((b) {
        b
          ..name = '_selectedFields'
          ..type = TypeReference((t) => t
            ..symbol = 'List'
            ..types.add(TypeReference((b) => b..symbol = 'String')))
          ..assignment = Code('[]');
      }));

      // Add select(List<String> fields)
      clazz.methods.add(Method((m) {
        m
          ..name = 'select'
          ..returns = refer('${rc.pascalCase}Query')
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'selectedFields'
            ..type = TypeReference((t) => t
              ..symbol = 'List'
              ..types.add(TypeReference((b) => b..symbol = 'String')))
            ..named = true))
          ..body = Block((b) {
            b.addExpression(
              refer('_selectedFields').assign(refer('selectedFields')),
            );
            b.addExpression(refer('this').returned);
          });
      }));

      // Add _where member
      clazz.fields.add(Field((b) {
        b
          ..name = '_where'
          ..type = nullableQueryWhereType;
      }));

      // Add where getter
      clazz.methods.add(Method((b) {
        b
          ..name = 'where'
          ..type = MethodType.getter
          ..returns = nullableQueryWhereType
          ..annotations.add(refer('override'))
          ..body = Block((b) => b.addExpression(refer('_where').returned));
      }));

      // Add parseRow()
      clazz.methods.add(Method((m) {
        m
          ..name = 'parseRow'
          ..returns = refer('Optional<${rc.pascalCase}>')
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'row'
            ..type = refer('List')
            ..named = true))
          ..body = Block((b) {
            var i = 0;
            var args = <String, Expression>{};
            for (var field in ctx.effectiveFields) {
              var fType = field.type;
              Reference type = convertTypeReference(fType);
              if (isSpecialId(ctx, field)) {
                type = refer('int');
              }
              var expr = refer('row').index(literalNum(i++));
              if (isSpecialId(ctx, field)) {
                expr = expr.property('toString').call([]);
              } else if (field is RelationFieldImpl) {
                continue;
              } else if (ctx.columns[field.name]?.type == ColumnType.json) {
                expr = refer('json')
                    .property('decode')
                    .call([expr.asA(refer('String'))]).asA(type);
              } else if (floatTypes.contains(ctx.columns[field.name]?.type)) {
                expr = refer('mapToDouble').call([expr]);
              } else if (fType is InterfaceType &&
                  fType.element is EnumElement) {
                var isNull = expr.equalTo(literalNull);
                final parseExpression = _deserializeEnumExpression(field, expr);
                expr = isNull.conditional(literalNull, parseExpression);
              } else if (fType.isDartCoreInt) {
                expr = refer('mapToInt').call([expr]);
              } else if (fType.isDartCoreBool) {
                expr = refer('mapToBool').call([expr]);
              } else if (fType.element?.displayName == 'DateTime') {
                if (fType.nullabilitySuffix == NullabilitySuffix.question) {
                  expr = refer('mapToNullableDateTime').call([expr]);
                } else {
                  expr = refer('mapToDateTime').call([expr]);
                }
              } else {
                expr = expr.asA(type);
              }
              Expression defaultRef = refer('null');
              if (fType.nullabilitySuffix != NullabilitySuffix.question) {
                if (fType.isDartCoreString) {
                  defaultRef = CodeExpression(Code('\'\''));
                } else if (fType.isDartCoreBool) {
                  defaultRef = CodeExpression(Code('false'));
                } else if (fType.isDartCoreDouble) {
                  defaultRef = CodeExpression(Code('0.0'));
                } else if (fType.isDartCoreInt || fType.isDartCoreNum) {
                  defaultRef = CodeExpression(Code('0'));
                } else if (fType.element?.displayName == 'DateTime') {
                  defaultRef = CodeExpression(
                      Code('DateTime.parse("1970-01-01 00:00:00")'));
                } else if (fType.isDartCoreList) {
                  defaultRef = CodeExpression(Code('[]'));
                }
              }
              expr = refer('fields').property('contains').call([
                literalString(ctx.buildContext.resolveFieldName(field.name)!)
              ]).conditional(expr, defaultRef);
              args[field.name] = expr;
            }
            b.statements.add(Code(
                'if (row.every((x) => x == null)) { return Optional.empty(); }'));
            b.addExpression(declareVar('model')
                .assign(ctx.buildContext.modelClassType.newInstance([], args)));
            ctx.relations.forEach((name, relation) {
              if (!const [
                RelationshipType.hasOne,
                RelationshipType.belongsTo,
                RelationshipType.hasMany
              ].contains(relation.type)) {
                return;
              }
              var foreign = relation.foreign;
              if (foreign == null) {
                log.warning('Foreign relationship for field $name is null');
                return;
              }
              var skipToList = refer('row')
                  .property('skip')
                  .call([literalNum(i)])
                  .property('take')
                  .call([literalNum(foreign.effectiveFields.length)])
                  .property('toList')
                  .call([]);
              var parsed = refer(
                      '${foreign.buildContext.modelClassNameRecase.pascalCase}Query')
                  .newInstance([], {})
                  .property('parseRow')
                  .call([], {refer('row').toString(): skipToList});
              var val =
                  (relation.type == RelationshipType.hasMany) ? '[m]' : 'm';
              var code = Code('''
              modelOpt.ifPresent((m) {
                model = model.copyWith($name: $val);
              })
            ''');
              var block = Block((b) {
                b.addExpression(declareVar('modelOpt').assign(parsed));
                b.addExpression(CodeExpression(code));
              });
              var blockStr =
                  block.accept(DartEmitter(useNullSafetySyntax: true));
              var ifStr = 'if (row.length > $i) { $blockStr }';
              b.statements.add(Code(ifStr));
              i += foreign.effectiveFields.length;
            });
            b.addExpression(
                refer('Optional.of').call([refer('model')]).returned);
          });
      }));

      // Add deserialize method
      clazz.methods.add(Method((m) {
        m
          ..name = 'deserialize'
          ..returns = refer('Optional<${rc.pascalCase}>')
          ..annotations.add(refer('override'))
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'row'
            ..type = refer('List')
            ..named = true))
          ..body = Block((b) {
            b.addExpression(refer('parseRow')
                .call([], {refer('row').toString(): refer('row')}).returned);
          });
      }));

      // If there are any relations, we need some overrides.
      clazz.constructors.add(Constructor((b) {
        b
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'parent'
            ..type = refer('Query')))
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'trampoline'
            ..type = refer('Set<String>')))
          ..initializers.add(Code('super(parent: parent)'))
          ..body = Block((b) {
            b.statements.addAll([
              Code('trampoline ??= <String>{};'),
              Code('trampoline.add(tableName);'),
            ]);
            ctx.columns.forEach((name, col) {
              if (col.hasExpression) {
                var lhs = refer('expressions').index(
                    literalString(ctx.buildContext.resolveFieldName(name)!));
                var rhs = literalString(col.expression!);
                b.addExpression(lhs.assign(rhs));
              }
            });

            b.addExpression(refer('_where').assign(
                queryWhereType.newInstance([], {'query': refer('this')})));
            ctx.relations.forEach((fieldName, relation) {
              if (relation.type == RelationshipType.belongsTo ||
                  relation.type == RelationshipType.hasOne ||
                  relation.type == RelationshipType.hasMany) {
                var relationForeign = relation.foreign;
                if (relationForeign == null) {
                  log.warning('$fieldName has no relationship in the context');
                  return;
                }
                var relationContext =
                    relation.throughContext ?? relation.foreign;
                var additionalStrs = relationForeign.effectiveFields.map((f) =>
                    relationForeign.buildContext.resolveFieldName(f.name));
                var additionalFields = <Expression>[];
                for (var element in additionalStrs) {
                  if (element != null) {
                    additionalFields.add(literalString(element));
                  }
                }
                var joinArgs = <Expression>[];
                for (var element in [relation.localKey, relation.foreignKey]) {
                  if (element != null) {
                    joinArgs.add(literalString(element));
                  }
                }
                if (relation.isManyToMany) {
                  var foreignFields = additionalStrs
                      .map((f) => '${relationForeign.tableName}.$f');
                  var b = StringBuffer('(SELECT ');
                  b.write('${relationContext?.tableName}');
                  b.write('.${relation.foreignKey}');
                  b.write(foreignFields.isEmpty
                      ? ''
                      : ', ${foreignFields.join(', ')}');
                  b.write(' FROM ');
                  b.write(relationForeign.tableName);
                  b.write(' LEFT JOIN ${relationContext?.tableName}');
                  var throughRelation =
                      relationContext?.relations.values.firstWhere((e) {
                    return e.foreignTable == relationForeign.tableName;
                  }, orElse: () {
                    var b = StringBuffer();
                    b.write(ctx.buildContext.modelClassName);
                    b.write(' has a many-to-many relationship to ');
                    b.write(relationForeign.buildContext.modelClassName);
                    b.write(' through ');
                    b.write(relationContext.buildContext.modelClassName);
                    b.write(', but ');
                    b.write(relationContext.buildContext.modelClassName);
                    b.write(' has no relation pointing to ');
                    b.write(ctx.buildContext.modelClassName);
                    b.write('.');
                    throw b.toString();
                  });
                  b.write(' ON ');
                  b.write('${relation.throughContext!.tableName}');
                  b.write('.');
                  b.write(throughRelation?.localKey);
                  b.write('=');
                  b.write(relationForeign.tableName);
                  b.write('.');
                  b.write(throughRelation?.foreignKey);
                  b.write(')');
                  joinArgs.insert(0, literalString(b.toString()));
                } else {
                  var foreignQueryType = refer(
                      '${relationForeign.buildContext.modelClassNameRecase.pascalCase}Query');
                  clazz
                    ..fields.add(Field((b) => b
                      ..name = '_$fieldName'
                      ..late = true
                      ..type = foreignQueryType))
                    ..methods.add(Method((b) => b
                      ..name = fieldName
                      ..type = MethodType.getter
                      ..returns = foreignQueryType
                      ..body = refer('_$fieldName').returned.statement));
                  var queryInstantiation = foreignQueryType.newInstance(
                      [],
                      <String, Expression>{} as Map<String, Expression>,    //Mofification 30/05/2025 11h42 use {} instead of []
                      {
                        'trampoline': refer('trampoline'),
                        'parent': refer('this')
                      } as List<Reference>);
                  joinArgs.insert(
                      0, refer('_$fieldName').assign(queryInstantiation));
                }
                var joinType = relation.joinTypeString;
                b.addExpression(refer(joinType).call(joinArgs, {
                  'additionalFields': literalList(additionalFields),
                  'trampoline': refer('trampoline'),
                }));
              }
            });

            // If we have any many-to-many relations, we need to prevent fetching this table within their joins.
            var manyToMany =
                ctx.relations.entries.where((e) => e.value.isManyToMany);
            if (manyToMany.isNotEmpty) {
              var outExprs = manyToMany.map<Expression>((e) {
                var foreignTableName = e.value.throughContext!.tableName;
                return CodeExpression(Code('''
          (!(
            trampoline.contains('${ctx.tableName}')
            && trampoline.contains('$foreignTableName')
          ))
        '''));
              });
              var out = outExprs.reduce((a, b) => a.and(b));
              clazz.methods.add(Method((b) {
                b
                  ..name = 'canCompile'
                  ..annotations.add(refer('override'))
                  ..requiredParameters.add(Parameter((b) => b
                    ..name = 'trampoline'
                    ..named = true))
                  ..returns = refer('bool')
                  ..body = Block((b) {
                    b.addExpression(out.returned);
                  });
              }));
            }

            // Also, if there is a @HasMany, generate overrides for query methods that execute in a transaction, and invoke fetchLinked.
            if (ctx.relations.values
                .any((r) => r.type == RelationshipType.hasMany)) {
              for (var methodName in const ['get', 'update', 'delete']) {
                clazz.methods.add(Method((b) {
                  var type = ctx.buildContext.modelClassType
                      .accept(DartEmitter(useNullSafetySyntax: true));
                  b
                    ..name = methodName
                    ..returns = TypeReference((b) => b
                      ..symbol = 'Future'
                      ..types.add(TypeReference((b) => b
                        ..symbol = 'List'
                        ..types.add(TypeReference((b) => b
                          ..symbol = '$type'
                          ..isNullable = false)))))
                    ..annotations.add(refer('override'))
                    ..requiredParameters.add(Parameter((b) => b
                      ..name = 'executor'
                      ..type = refer('QueryExecutor')
                      ..named = true));
                  var merge = <String>[];
                  ctx.relations.forEach((name, relation) {
                    if (relation.type == RelationshipType.hasMany) {
                      var field = ctx.buildContext.fields
                          .firstWhere((f) => f.name == name);
                      var typeLiteral = convertTypeReference(field.type)
                          .accept(DartEmitter(useNullSafetySyntax: true))
                          .toString()
                          .replaceAll('?', '');
                      merge.add('''
                $name: $typeLiteral.from(l.$name)..addAll(model.$name)
              ''');
                    }
                  });
                  var merged = merge.join(', ');
                  var keyName =
                      findPrimaryFieldInList(ctx, ctx.buildContext.fields)
                          ?.name;
                  if (keyName == null) {
                    throw '${ctx.buildContext.originalClassName} has no defined primary key.\n'
                        '@HasMany and @ManyToMany relations require a primary key to be defined on the model.';
                  }
                  b.body = Code('''
            return super.$methodName(executor: executor).then((result) {
              return result.fold<List<$type>>([], (out, model) {
                var idx = out.indexWhere((m) => m.$keyName == model.$keyName);
                if (idx == -1) {
                  return out..add(model);
                } else {
                  var l = out[idx];
                  return out..[idx] = l.copyWith($merged);
                }
              });
            });
          ''');
                }));
              }
            }
          });
      }));
    });
  }

  /// Generate <Model>QueryWhere class
  Class buildWhereClass(OrmBuildContext ctx) {
    return Class((clazz) {
      var rc = ctx.buildContext.modelClassNameRecase;

      log.info('Generating ${rc.pascalCase}QueryWhere');

      clazz
        ..name = '${rc.pascalCase}QueryWhere'
        ..extend = refer('QueryWhere');

      // Build expressionBuilders getter
      clazz.methods.add(Method((m) {
        m
          ..name = 'expressionBuilders'
          ..returns = refer('List<SqlExpressionBuilder>')
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = Block((b) {
            var references =
                ctx.effectiveNormalFields.map((f) => refer(f.name));
            b.addExpression(literalList(references).returned);
          });
      }));

      var initializers = <Code>[];

      // Add builders for each field
      for (var field in ctx.effectiveNormalFields) {
        String? name = field.name;

        var args = <Expression>[];
        DartType type;
        Reference builderType;

        try {
          type = ctx.buildContext.resolveSerializedFieldType(field.name);
        } on StateError {
          type = field.type;
        }

        if (const TypeChecker.fromRuntime(int).isExactlyType(type) ||
            const TypeChecker.fromRuntime(double).isExactlyType(type) ||
            isSpecialId(ctx, field)) {
          var typeName = type.getDisplayString().replaceAll('?', '');
          if (isSpecialId(ctx, field)) {
            typeName = 'int';
          }
          builderType = TypeReference((b) => b
            ..symbol = 'NumericSqlExpressionBuilder'
            ..types.add(refer(typeName)));
        } else if (type is InterfaceType && type.element is EnumElement) {
          builderType = TypeReference((b) => b
            ..symbol = 'EnumSqlExpressionBuilder'
            ..types.add(convertTypeReference(type)));

          var question =
              type.nullabilitySuffix == NullabilitySuffix.question ? '?' : '';
          args.add(CodeExpression(Code('(v) => v$question.index as int')));
        } else if (const TypeChecker.fromRuntime(String).isExactlyType(type)) {
          builderType = refer('StringSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(bool).isExactlyType(type)) {
          builderType = refer('BooleanSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(DateTime)
            .isExactlyType(type)) {
          builderType = refer('DateTimeSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(Map)
            .isAssignableFromType(type)) {
          builderType = refer('MapSqlExpressionBuilder');
        } else if (const TypeChecker.fromRuntime(List)
            .isAssignableFromType(type)) {
          builderType = refer('ListSqlExpressionBuilder');
        } else if (name.endsWith('Id')) {
          log.fine('Foreign Relationship detected = $name');
          var relation = ctx.relations[name.replaceAll('Id', '')];
          if (relation != null) {
            builderType = TypeReference((b) => b
              ..symbol = 'NumericSqlExpressionBuilder'
              ..types.add(refer('int')));
          } else {
            log.warning(
                'Cannot generate ORM code for field ${field.name} of type ${field.type}');
            continue;
          }
        } else {
          log.warning(
              'Cannot generate ORM code for field ${field.name} of type ${field.type}');
          continue;
        }

        clazz.fields.add(Field((b) {
          b
            ..name = name
            ..modifier = FieldModifier.final$
            ..type = builderType;

          var literal = ctx.buildContext.resolveFieldName(field.name);
          if (literal != null) {
            initializers.add(
              refer(field.name)
                  .assign(builderType.newInstance(
                      [refer('query'), literalString(literal)], {}))
                  .code,
            );
          } else {
            log.warning('Literal ${field.name} is null');
          }
        }));
      }

      // Now, just add a constructor that initializes each builder.
      clazz.constructors.add(Constructor((b) {
        b
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'query'
            ..type = refer('${rc.pascalCase}Query')
            ..named = true))
          ..initializers.addAll(initializers);
      }));
    });
  }

  /// Generate <Model>QueryValues class
  Class buildValuesClass(OrmBuildContext ctx) {
    return Class((clazz) {
      var rc = ctx.buildContext.modelClassNameRecase;

      log.info('Generating ${rc.pascalCase}QueryValues');

      clazz
        ..name = '${rc.pascalCase}QueryValues'
        ..extend = refer('MapQueryValues');

      // Override casts so that we can cast Lists
      clazz.methods.add(Method((b) {
        b
          ..name = 'casts'
          ..returns = refer('Map<String, String>')
          ..annotations.add(refer('override'))
          ..type = MethodType.getter
          ..body = Block((b) {
            var args = <String?, Expression>{};

            for (var field in ctx.effectiveFields) {
              var fType = field.type;
              var name = ctx.buildContext.resolveFieldName(field.name);
              var type = ctx.columns[field.name]?.type;
              if (type == null) continue;
              if (const TypeChecker.fromRuntime(List)
                  .isAssignableFromType(fType)) {
                args[name] = literalString(type.name);
              }
            }

            b.addExpression(literalMap(args).returned);
          });
      }));

      // Each field generates a getter and setter
      for (var field in ctx.effectiveNormalFields) {
        var fType = field.type;
        var name = ctx.buildContext.resolveFieldName(field.name);
        var type = convertTypeReference(field.type);

        clazz.methods.add(Method((b) {
          var value = refer('values').index(literalString(name!));

          if (fType is InterfaceType && fType.element is EnumElement) {
            value = _deserializeEnumExpression(field, value);
          } else if (const TypeChecker.fromRuntime(List)
              .isAssignableFromType(fType)) {
            value = refer('json')
                .property('decode')
                .call([value.asA(refer('String'))])
                .property('cast')
                .call([]);
          } else if (floatTypes.contains(ctx.columns[field.name]?.type)) {
            value = value
                .asA(refer('double?'))
                .ifNullThen(CodeExpression(Code('0.0')));
          } else {
            value = value.asA(type);
          }

          b
            ..name = field.name
            ..type = MethodType.getter
            ..returns = type
            ..body = Block((b) => b.addExpression(value.returned));
        }));

        clazz.methods.add(Method((b) {
          Expression value = refer('value');

          if (fType is InterfaceType && fType.element is EnumElement) {
            value = _serializeEnumExpression(field, value);
          } else if (const TypeChecker.fromRuntime(List)
              .isAssignableFromType(fType)) {
            value = refer('json').property('encode').call([value]);
          }

          b
            ..name = field.name
            ..type = MethodType.setter
            ..requiredParameters.add(Parameter((b) => b
              ..name = 'value'
              ..type = type
              ..named = true))
            ..body =
                refer('values').index(literalString(name!)).assign(value).code;
        }));
      }

      // Add model
      clazz.methods.add(Method((b) {
        b
          ..name = 'copyFrom'
          ..returns = refer('void')
          ..requiredParameters.add(Parameter((b) => b
            ..name = 'model'
            ..type = ctx.buildContext.modelClassType
            ..named = true))
          ..body = Block((b) {
            for (var field in ctx.effectiveNormalFields) {
              if (isSpecialId(ctx, field) || field is RelationFieldImpl) {
                continue;
              }
              b.addExpression(refer(field.name)
                  .assign(refer('model').property(field.name)));
            }

            for (var field in ctx.effectiveNormalFields) {
              if (field is RelationFieldImpl) {
                var original = field.originalFieldName;

                var prop = refer('model').property(original);

                var target = refer('values').index(literalString(
                    ctx.buildContext.resolveFieldName(field.name)!));

                var foreign = field.relationship.throughContext ??
                    field.relationship.foreign;
                var foreignField = field.relationship.findForeignField(ctx);

                var parsedId = prop.nullSafeProperty(foreignField.name);

                if (foreign != null) {
                  if (isSpecialId(foreign, field)) {
                    parsedId =
                        (refer('int').property('tryParse').call([parsedId]));
                  }
                }
                var cond = prop.notEqualTo(literalNull);
                var condStr =
                    cond.accept(DartEmitter(useNullSafetySyntax: true));
                var blkStr =
                    Block((b) => b.addExpression(target.assign(parsedId)))
                        .accept(DartEmitter(useNullSafetySyntax: true));
                var ifStmt = Code('if ($condStr) { $blkStr }');
                b.statements.add(ifStmt);
              }
            }
          });
      }));
    });
  }

  /// Retrieve the [Expression] to parse a serialized enumeration field.
  /// Takes into account the [SerializableField] properties.
  /// Defaults to `enum.values[index as int]`
  Expression _deserializeEnumExpression(FieldElement field, Expression expr) {
    Reference enumType =
        convertTypeReference(field.type, ignoreNullabilityCheck: true);
    const TypeChecker serializableFieldTypeChecker =
        TypeChecker.fromRuntime(SerializableField);
    final annotation = serializableFieldTypeChecker.firstAnnotationOf(field);
    Expression? parseExpr;
    if (null != annotation) {
      final deserializer = annotation.getField('deserializer')?.toSymbolValue();
      if (null != deserializer) {
        var type = 'int';
        final serializesTo = annotation.getField('serializesTo')?.toTypeValue();
        if (null != serializesTo) {
          type = serializesTo.element!.displayName;
        }
        parseExpr = Reference(deserializer).expression([expr.asA(refer(type))]);
      }
    }

    //return parseExpr ??
    //    enumType.property('values').index(expr.asA(refer('int')));

    if (parseExpr != null) {
      return parseExpr;
    }

    return enumType.property('values').index(refer('mapToInt').call([expr]));
  }

  /// Retrieve the [Expression] to serialize the enumeration field.
  /// Takes into account the [SerializableField] properties.
  Expression _serializeEnumExpression(FieldElement field, Expression expr) {
    const TypeChecker serializableFieldTypeChecker =
        TypeChecker.fromRuntime(SerializableField);
    final annotation = serializableFieldTypeChecker.firstAnnotationOf(field);
    Expression? parseExpr;
    if (null != annotation) {
      final serializer = annotation.getField('serializer')?.toSymbolValue();
      if (null != serializer) {
        parseExpr = Reference(serializer).expression([expr]);
      }
    }
    return parseExpr ?? CodeExpression(Code('value?.index'));
  }
}
