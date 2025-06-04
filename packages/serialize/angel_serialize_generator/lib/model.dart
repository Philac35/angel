part of 'angel3_serialize_generator.dart';

class JsonModelGenerator extends GeneratorForAnnotation<Serializable> {
  const JsonModelGenerator();

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element.kind != ElementKind.CLASS) {
      throw 'Only classes can be annotated with a @Serializable() annotation.';
    }

    var ctx = await buildContext(element as ClassElement, annotation, buildStep,
        buildStep.resolver, true);

    if (ctx == null) {
      log.fine('Invalid builder context');
      throw 'Invalid builder context';
    }

    var lib = Library((b) {
      generateClass(ctx, b, annotation);
    });

    var buf = lib.accept(DartEmitter(useNullSafetySyntax: true));
    return buf.toString();
  }

  /// Generate an extended model class. Modification EH 4/06/2025 16h04
  void generateClass( BuildContext ctx, LibraryBuilder file, ConstantReader annotation,builderOptions, {buildStep.inputId.package}) {

    // Helper function to read class name suffix from build configuration
    String _getClassNameSuffix(BuilderOptions builderOptions, ConstantReader annotation) {
      // Priority 1: Read from build.yaml configuration
      var configSuffix = builderOptions.config['class_name_suffix'] as String?;
      if (configSuffix != null && configSuffix.isNotEmpty) {
        return configSuffix;
      }

      // Priority 2: Read from annotation parameters (if you want to support this)
      try {
        var annotationSuffix = annotation.read('classNameSuffix').stringValue;
        if (annotationSuffix.isNotEmpty) {
          return annotationSuffix;
        }
      } catch (e) {
        // Annotation parameter doesn't exist, continue to default
      }

      // Priority 3: Default fallback
      return 'Impl';
    }

    file.body.add(Class((clazz) {

      // SOLUTION FOR NAME COLLISION:
      // Generate a unique class name instead of using the same name
      var originalClassName = ctx.modelClassNameRecase.pascalCase;

      // Get class name suffix from configuration
      var classNameSuffix = _getClassNameSuffix(builderOptions, annotation);
      var generatedClassName = '$originalClassName$classNameSuffix'; // or use 'Generated' suffix


  //log.fine('Generate Class: $generatedClassName');
      clazz
        ..name = generatedClassName //Use unique name to avoid collision//ctx.modelClassNameRecase.pascalCase
        ..extend = refer(originalClassName) //Extend the original abstract class
        ..annotations.add(refer('generatedSerializable'));



      for (var ann in ctx.includeAnnotations) {
        clazz.annotations.add(convertObject(ann));
      }

      if (shouldBeConstant(ctx)) {
        clazz.implements.add(Reference(ctx.originalClassName));
      } else {
        clazz.extend = Reference(ctx.originalClassName);
      }

      //if (ctx.importsPackageMeta)
      //  clazz.annotations.add(CodeExpression(Code('immutable')));

      // Generate the fields for the class
      for (var field in ctx.fields) {
        //log.fine('Generate Field: ${field.name}');

        clazz.fields.add(Field((b) {
          b
            ..name = field.name
            //..modifier = FieldModifier.final$
            //..annotations.add(CodeExpression(Code('override')))
            ..annotations.add(refer('override'))
            ..type = convertTypeReference(field.type);

          // Fields should only be forced-final if the original field has no setter.
          //log.fine('Final: ${field.isFinal}');
          //if (field.setter == null && field is! ShimFieldImpl) {
          //if (field.isFinal) {
          //  b.modifier = FieldModifier.final$;
          //}

          for (var el in [field.getter, field]) {
            if (el?.documentationComment != null) {
            b.docs.addAll(el?.documentationComment?.split('\n') ?? []);
            }
          }
        }));
      }

      generateConstructor(ctx, clazz, file);
      generateCopyWithMethod(ctx, clazz, file);
      generateEqualsOperator(ctx, clazz, file);
      generateHashCode(ctx, clazz);
      generateToString(ctx, clazz);

      // Generate toJson() method if necessary
      var serializers = annotation.peek('serializers')?.listValue ?? [];

      if (serializers.any((o) => o.toIntValue() == Serializers.json)) {
        clazz.methods.add(Method((method) {
          method
            ..name = 'toJson'
            ..returns = Reference('Map<String, dynamic>')
            ..body = Code('return ${clazz.name}Serializer.toMap(this);');
        }));
      }
    }));
  }

  bool shouldBeConstant(BuildContext ctx) {
    // Check if all fields are without a getter
    return !isAssignableToModel(ctx.clazz.thisType) &&
        ctx.clazz.fields.every((f) =>
            f.getter?.isAbstract != false && f.setter?.isAbstract != false);
  }

  /// Generate a constructor with ONLY named parameters.
  void generateConstructor(
      BuildContext ctx, ClassBuilder clazz, LibraryBuilder file) {
    clazz.constructors.add(Constructor((constructor) {
      // Note: Removed constant constructor logic for clarity
      // Add it back if needed based on your requirements

      // CHANGE 1: Convert all constructor parameters to named parameters
      // Instead of adding to requiredParameters, add everything to optionalParameters as named
      for (var param in ctx.constructorParameters) {
        constructor.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type)
          ..named = true  // Force named parameter
          ..required = true  // Make it required named parameter
        ));
      }

      // Generate initializers (unchanged)
      for (var field in ctx.fields) {
        if (!shouldBeConstant(ctx) && isListOrMapType(field.type)) {
          var typeName = const TypeChecker.fromRuntime(List)
              .isAssignableFromType(field.type)
              ? 'List'
              : 'Map';
          String? defaultValue = typeName == 'List' ? '[]' : '{}';

          var existingDefault = ctx.defaults[field.name];
          if (existingDefault != null) {
            defaultValue = dartObjectToString(existingDefault);
          }

          if (field.type.nullabilitySuffix != NullabilitySuffix.question) {
            constructor.initializers.add(Code('''
            ${field.name} =
              $typeName.unmodifiable(${field.name})'''));
          } else {
            constructor.initializers.add(Code('''
            ${field.name} =
              $typeName.unmodifiable(${field.name} ?? $defaultValue)'''));
          }
        }
      }

      // CHANGE 2: All field parameters are already named, just ensure consistency
      for (var field in ctx.fields) {
        constructor.optionalParameters.add(Parameter((b) {
          b
            ..toThis = shouldBeConstant(ctx)
            ..name = field.name
            ..named = true;  // Ensure this stays named

          var existingDefault = ctx.defaults[field.name];

          if (existingDefault != null) {
            var d = dartObjectToString(existingDefault);
            if (d != null) {
              b.defaultTo = Code(d);
            }
          }

          if (!isListOrMapType(field.type)) {
            b.toThis = true;
          } else if (isListType(field.type)) {
            if (!b.toThis) {
              b.type = convertTypeReference(field.type);
            }

            // Get the default if present
            var existingDefault = ctx.defaults[field.name];
            if (existingDefault != null) {
              var defaultValue = dartObjectToString(existingDefault);
              b.defaultTo = Code('$defaultValue');
            } else {
              b.defaultTo = Code('const []');
            }
          } else if (!b.toThis) {
            b.type = convertTypeReference(field.type);
          }

          // CHANGE 3: Handle required parameters properly for named parameters
          if ((ctx.requiredFields.containsKey(field.name) ||
              field.type.nullabilitySuffix != NullabilitySuffix.question) &&
              b.defaultTo == null) {
            b.required = true;  // Make it a required named parameter
          }
        }));
      }

      // CHANGE 4: Update super constructor call to use named parameters
      if (ctx.constructorParameters.isNotEmpty) {
        if (!shouldBeConstant(ctx) ||
            ctx.clazz.unnamedConstructor?.isConst == true) {
          // Build named parameter call to super constructor
          var superParams = ctx.constructorParameters
              .map((p) => '${p?.name}: ${p?.name}')
              .join(', ');
          constructor.initializers.add(Code('super($superParams)'));
        }
      }
    }));
  }

  /// Generate a `copyWith` method.
  void generateCopyWithMethod(
      BuildContext ctx, ClassBuilder clazz, LibraryBuilder file) {
    clazz.methods.add(Method((method) {
      method
        ..name = 'copyWith'
        ..returns = ctx.modelClassType;

      // Add all `super` params
      if (ctx.constructorParameters.isNotEmpty) {
        for (var param in ctx.constructorParameters) {
          method.requiredParameters.add(Parameter((b) => b
            ..name = param.name
            ..type = convertTypeReference(param.type)));
        }
      }

      var buf = StringBuffer('return ${ctx.modelClassName}(');
      var i = 0;
      for (var param in ctx.constructorParameters) {
        if (i++ > 0) buf.write(', ');
        buf.write(param.name);
      }

      // Add named parameters
      for (var field in ctx.fields) {
        method.optionalParameters.add(Parameter((b) {
          b
            ..name = field.name
            ..named = true
            ..type = convertTypeReference(field.type, forceNullable: true);
        }));

        if (i++ > 0) buf.write(', ');
        buf.write('${field.name}: ${field.name} ?? this.${field.name}');
      }

      buf.write(');');
      method.body = Code(buf.toString());
    }));
  }

  static String? generateEquality(DartType type, [bool nullable = false]) {
    if (type is InterfaceType) {
      if (const TypeChecker.fromRuntime(List).isAssignableFromType(type)) {
        if (type.typeArguments.length == 1) {
          var eq = generateEquality(type.typeArguments[0]);
          return 'ListEquality<${type.typeArguments[0].element!.name}>($eq)';
        } else {
          return 'ListEquality()';
        }
      } else if (const TypeChecker.fromRuntime(Map)
          .isAssignableFromType(type)) {
        if (type.typeArguments.length == 2) {
          var keq = generateEquality(type.typeArguments[0]),
              veq = generateEquality(type.typeArguments[1]);
          return 'MapEquality<${type.typeArguments[0].element!.name}, ${type.typeArguments[1].element!.name}>(keys: $keq, values: $veq)';
        } else {
          return 'MapEquality()';
        }
      }

      return nullable ? null : 'DefaultEquality<${type.element.name}>()';
    } else {
      return 'DefaultEquality()';
    }
  }

  static String Function(String, String) generateComparator(DartType type) {
    if (type is! InterfaceType || type.element.displayName == 'dynamic') {
      return (a, b) => '$a == $b';
    }
    var eq = generateEquality(type, true);
    if (eq == null) return (a, b) => '$a == $b';
    return (a, b) => '$eq.equals($a, $b)';
  }

  void generateHashCode(BuildContext? ctx, ClassBuilder clazz) {
    clazz.methods.add(Method((method) {
      method
        ..name = 'hashCode'
        ..type = MethodType.getter
        ..returns = refer('int')
        ..annotations.add(refer('override'))
        ..body = refer('hashObjects')
            .call([literalList(ctx!.fields.map((f) => refer(f.name)))])
            .returned
            .statement;
    }));
  }

  void generateToString(BuildContext? ctx, ClassBuilder clazz) {
    clazz.methods.add(Method((b) {
      b
        ..name = 'toString'
        ..returns = refer('String')
        ..annotations.add(refer('override'))
        ..body = Block((b) {
          var buf = StringBuffer('\'${ctx!.modelClassName}(');
          var i = 0;
          for (var field in ctx.fields) {
            if (i++ > 0) buf.write(', ');
            buf.write('${field.name}=\$${field.name}');
          }
          buf.write(')\'');
          b.addExpression(CodeExpression(Code(buf.toString())).returned);
        });
    }));
  }

  void generateEqualsOperator(
      BuildContext? ctx, ClassBuilder clazz, LibraryBuilder file) {
    clazz.methods.add(Method((method) {
      method
        ..name = 'operator =='
        ..annotations.add(refer('override'))
        ..returns = Reference('bool')
        ..requiredParameters.add(Parameter((b) => b.name = 'other'));

      var buf = ['other is ${ctx!.originalClassName}'];

      buf.addAll(ctx.fields.map((f) {
        return generateComparator(f.type)('other.${f.name}', f.name);
      }));

      method.body = Code('return ${buf.join('&&')};');
    }));
  }
}
