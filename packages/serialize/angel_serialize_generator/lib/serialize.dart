

part of 'angel3_serialize_generator.dart';

class SerializerGenerator extends GeneratorForAnnotation<Serializable> {
  final bool autoSnakeCaseNames;

  const SerializerGenerator({this.autoSnakeCaseNames = true});

  @override
  Future<String?> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    log.fine('Running SerializerGenerator');

    if (element.kind != ElementKind.CLASS) {
      throw 'Only classes can be annotated with a @Serializable() annotation.';
    }

    var ctx = await buildContext(element as ClassElement, annotation, buildStep,
        buildStep.resolver, !autoSnakeCaseNames);

    if (ctx == null) {
      log.severe('Invalid builder context');
      throw 'Invalid builder context';
    }

    var serializers = annotation.peek('serializers')?.listValue ?? [];

    if (serializers.isEmpty) {
      log.severe("No Serializers");
      return null;
    }

    if (!serializers.any((s) => Serializers.all.contains(s.toIntValue()))) {
      log.severe("No recognizable Serializers");
      return null;
    }

    var lib = Library((b) {
      generateClass(
          serializers.map((s) => s.toIntValue() ?? 0).toList(), ctx, b);
      generateFieldsClass(ctx, b);
    });

    var buf = lib.accept(DartEmitter(useNullSafetySyntax: true));
    return buf.toString();
  }

  void generateClass(
      List<int> serializers, BuildContext ctx, LibraryBuilder file) {
    log.fine('Generate serializer class');

    var pascal = ctx.modelClassNameRecase.pascalCase.replaceAll('?', '');
    var camel = ctx.modelClassNameRecase.camelCase.replaceAll('?', '');

    log.fine('Generating ${pascal}Serializer');

    if (ctx.constructorParameters.isEmpty) {
      log.fine("Constructor is empty");

      file.body.add(Code('''
const ${pascal}Serializer ${camel}Serializer = ${pascal}Serializer();

class ${pascal}Encoder extends Converter<$pascal, Map> {
  const ${pascal}Encoder();

  @override
  Map convert($pascal model) => ${pascal}Serializer.toMap(model);
}

class ${pascal}Decoder extends Converter<Map, $pascal> {
  const ${pascal}Decoder();

  @override
  $pascal convert(Map map) => ${pascal}Serializer.fromMap(map);
}
      '''));
    }

    file.body.add(Class((clazz) {
      clazz.name = '${pascal}Serializer';
      if (ctx.constructorParameters.isEmpty) {
        clazz.extend = TypeReference((b) => b
          ..symbol = 'Codec'
          ..types.addAll([ctx.modelClassType, refer('Map')]));

        generateConstructor(ctx, clazz);
        generateCopyWithMethod(ctx, clazz);

        clazz.methods.add(Method((b) => b
          ..name = 'encoder'
          ..returns = refer('${pascal}Encoder')
          ..type = MethodType.getter
          ..annotations.add(refer('override'))
          ..body = refer('${pascal}Encoder').constInstance([]).code));

        clazz.methods.add(Method((b) => b
          ..name = 'decoder'
          ..returns = refer('${pascal}Decoder')
          ..type = MethodType.getter
          ..annotations.add(refer('override'))
          ..body = refer('${pascal}Decoder').constInstance([]).code));
      } else {
        clazz.abstract = true;
      }

      if (serializers.contains(Serializers.map)) {
        generateFromMapMethod(clazz, ctx, file);
      }

      if (serializers.contains(Serializers.map) ||
          serializers.contains(Serializers.json)) {
        generateToMapMethod(clazz, ctx, file);
      }
    }));
  }

  void generateConstructor(BuildContext ctx, ClassBuilder clazz) {
    if (ctx.constructorParameters.isEmpty) return;

    clazz.constructors.add(Constructor((constructor) {
      var allConstructorParams = _collectAllConstructorParameters(ctx);
      var paramIndex = 0;

      var inheritedParams = _getInheritedParameters(ctx, allConstructorParams);
      for (var param in inheritedParams) {
        constructor.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type)
          ..named = true
          ..required = param.type.nullabilitySuffix !=  NullabilitySuffix.question));
      }

      var currentClassFields = ctx.fields.where((field) =>
      !_isInheritedField(field.name, inheritedParams)).toList();

      for (var field in currentClassFields) {
        constructor.optionalParameters.add(Parameter((b) => b
          ..name = field.name
          ..type = convertTypeReference(field.type)
          ..named = true
          ..toThis = true
          ..required = field.type.nullabilitySuffix !=  NullabilitySuffix.question));
      }

      var additionalParams = _getAdditionalConstructorParameters(ctx, allConstructorParams);
      for (var param in additionalParams) {
        constructor.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type)
          ..named = true
          ..required = param.type.nullabilitySuffix != NullabilitySuffix.question));
      }

      if (inheritedParams.isNotEmpty || additionalParams.isNotEmpty) {
        var superParams = <String>[];

        for (var param in inheritedParams) {
          superParams.add('${param.name}: ${param.name}');
        }

        for (var param in additionalParams) {
          if (_shouldPassToSuper(param.name)) {
            superParams.add('${param.name}: ${param.name}');
          }
        }

        if (superParams.isNotEmpty) {
          constructor.initializers.add(Code('super(${superParams.join(', ')})'));
        }
      }
    }));
  }

  void generateCopyWithMethod(BuildContext ctx, ClassBuilder clazz) {
    clazz.methods.add(Method((method) {
      method
        ..name = 'copyWith'
        ..returns = ctx.modelClassType;

      var allConstructorParams = _collectAllConstructorParameters(ctx);
      var inheritedParams = _getInheritedParameters(ctx, allConstructorParams);
      var currentClassFields = ctx.fields.where((field) =>
      !_isInheritedField(field.name, inheritedParams)).toList();
      var additionalParams = _getAdditionalConstructorParameters(ctx, allConstructorParams);

      for (var param in inheritedParams) {
        method.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type, forceNullable: true)
          ..named = true));
      }

      for (var field in currentClassFields) {
        method.optionalParameters.add(Parameter((b) => b
          ..name = field.name
          ..type = convertTypeReference(field.type, forceNullable: true)
          ..named = true));
      }

      for (var param in additionalParams) {
        method.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type, forceNullable: true)
          ..named = true));
      }

      var buf = StringBuffer();
      buf.writeln('return ${ctx.modelClassName}(');

      var paramIndex = 0;

      for (var param in inheritedParams) {
        if (paramIndex++ > 0) buf.write(', ');
        buf.write('${param.name}: ${param.name} ?? this.${param.name}');
      }

      for (var field in currentClassFields) {
        if (paramIndex++ > 0) buf.write(', ');
        buf.write('${field.name}: ${field.name} ?? this.${field.name}');
      }

      for (var param in additionalParams) {
        if (paramIndex++ > 0) buf.write(', ');
        if (_isFieldBasedParameter(param.name, ctx)) {
          buf.write('${param.name}: ${param.name} ?? this.${_getFieldForParameter(param.name)}?.id');
        } else {
          buf.write('${param.name}: ${param.name} ?? this.${param.name}');
        }
      }

      buf.write(');');
      method.body = Code(buf.toString());
    }));
  }

  void generateToMapMethod(ClassBuilder clazz, BuildContext ctx, LibraryBuilder file) {
    var originalClassName = ctx.originalClassName;
    if (originalClassName == null) {
      log.warning('Unable to generate toMap(), classname is null');
      return;
    }

    clazz.methods.add(Method((method) {
      method
        ..static = true
        ..name = 'toMap'
        ..returns = Reference('Map<String, dynamic>')
        ..requiredParameters.add(Parameter((b) {
          b
            ..name = 'model'
            ..type = TypeReference((b) => b
              ..symbol = originalClassName
              ..isNullable = true);
        }));

      var buf = StringBuffer();
      buf.writeln('if (model == null) { throw FormatException("Required field [model] cannot be null"); }');
      buf.writeln('return {');

      var i = 0;
      var allFields = _getAllSerializableFields(ctx);

      for (var field in allFields) {
        var type = ctx.resolveSerializedFieldType(field.name);
        if (ctx.excluded[field.name]?.canSerialize == false) continue;

        var alias = ctx.resolveFieldName(field.name);

        if (i++ > 0) buf.write(', ');

        var serializedRepresentation = 'model.${field.name}';
        var fieldNameSerializer = ctx.fieldInfo[field.name]?.serializer;

        if (fieldNameSerializer != null) {
          var name = MirrorSystem.getName(fieldNameSerializer);
          serializedRepresentation = '$name(model.${field.name})';
        } else if (dateTimeTypeChecker.isAssignableFromType(type)) {
          var question = field.type.nullabilitySuffix == NullabilitySuffix.question ? "?" : "";
          serializedRepresentation = 'model.${field.name}$question.toIso8601String()';
        } else if (isModelClass(type)) {
          var rc = ReCase(type.getDisplayString());
          serializedRepresentation = _serializerToMap(rc, 'model.${field.name}');
        } else if (type is InterfaceType) {
          serializedRepresentation = _handleInterfaceTypeSerialization(field, type, ctx);
        }

        buf.write("'$alias': $serializedRepresentation");
      }

      buf.write('};');
      method.body = Code(buf.toString());
    }));
  }

  void generateFromMapMethod(ClassBuilder clazz, BuildContext ctx, LibraryBuilder file) {
    clazz.methods.add(Method((method) {
      method
        ..static = true
        ..name = 'fromMap'
        ..returns = ctx.modelClassType
        ..requiredParameters.add(
          Parameter((b) => b
            ..name = 'map'
            ..type = Reference('Map')),
        );

      var allConstructorParams = _collectAllConstructorParameters(ctx);

      for (var param in allConstructorParams) {
        method.optionalParameters.add(Parameter((b) => b
          ..name = param.name
          ..type = convertTypeReference(param.type, forceNullable: true)
          ..named = true));
      }

      var buf = StringBuffer();

      ctx.requiredFields.forEach((key, msg) {
        if (ctx.excluded[key]?.canDeserialize == false) return;
        var name = ctx.resolveFieldName(key);
        if (msg.contains("'")) {
          buf.writeln('''
    if (map['$name'] == null) {
      throw FormatException("$msg");
    }
          ''');
        } else {
          buf.writeln('''
    if (map['$name'] == null) {
      throw FormatException('$msg');
    }
          ''');
        }
      });

      buf.writeln('return ${ctx.modelClassName}(');
      var paramIndex = 0;

      var inheritedParams = _getInheritedParameters(ctx, allConstructorParams);
      for (var param in inheritedParams) {
        if (paramIndex++ > 0) buf.write(', ');
        var paramValue = _generateParameterValue(param, ctx);
        buf.write('${param.name}: $paramValue');
      }

      var currentClassFields = ctx.fields.where((field) =>
      !_isInheritedField(field.name, inheritedParams)).toList();

      for (var field in currentClassFields) {
        if (ctx.excluded[field.name]?.canDeserialize == false) continue;
        if (paramIndex++ > 0) buf.write(', ');
        var deserializedValue = _generateDeserializationForField(field, ctx);
        buf.write('${field.name}: $deserializedValue');
      }

      var additionalParams = _getAdditionalConstructorParameters(ctx, allConstructorParams);
      for (var param in additionalParams) {
        if (paramIndex++ > 0) buf.write(', ');
        var paramValue = _generateParameterValue(param, ctx);
        buf.write('${param.name}: $paramValue');
      }

      buf.write(');');
      method.body = Code(buf.toString());
    }));
  }

  void generateFieldsClass(BuildContext ctx, LibraryBuilder file) {
    file.body.add(Class((clazz) {
      clazz
        ..abstract = true
        ..name = '${ctx.modelClassNameRecase.pascalCase}Fields';

      clazz.fields.add(Field((b) {
        b
          ..static = true
          ..modifier = FieldModifier.constant
          ..type = TypeReference((b) => b
            ..symbol = 'List'
            ..types.add(refer('String')))
          ..name = 'allFields'
          ..assignment = literalConstList(
              ctx.fields.map((f) => refer(f.name)).toList(),
              refer('String'))
              .code;
      }));

      for (var field in ctx.fields) {
        clazz.fields.add(Field((b) {
          b
            ..static = true
            ..modifier = FieldModifier.constant
            ..type = Reference('String')
            ..name = field.name
            ..assignment = Code("'${ctx.resolveFieldName(field.name)}'");
        }));
      }
    }));
  }

  List<FieldElement> _getAllSerializableFields(BuildContext ctx) {
    return ctx.fields;
  }

  String _serializerToMap(ReCase rc, String value) {
    return '${rc.pascalCase.replaceAll('?', '')}Serializer.toMap($value)';
  }

  String _handleInterfaceTypeSerialization(FieldElement field, InterfaceType type, BuildContext ctx) {
    var serializedRepresentation = 'model.${field.name}';

    if (isListOfModelType(type)) {
      var name = type.typeArguments[0].getDisplayString();
      if (name.startsWith('_')) name = name.substring(1);
      var rc = ReCase(name);
      var m = _serializerToMap(rc, 'm');
      var question = (field.type.nullabilitySuffix == NullabilitySuffix.question) ? '?' : '';
      serializedRepresentation = 'model.${field.name}$question.map((m) => $m).toList()';
    } else if (isMapToModelType(type)) {
      var rc = ReCase(type.typeArguments[1].getDisplayString());
      serializedRepresentation = '''model.${field.name}.keys.fold({}, (map, key) {
        return map..[key] = ${_serializerToMap(rc, 'model.${field.name}[key]')};
      })''';
    } else if (type.element is Enum) {
      var convert = (field.type.nullabilitySuffix == NullabilitySuffix.question) ? '!' : '';
      serializedRepresentation = '''
        model.${field.name} != null ?
          ${type.getDisplayString()}.values.indexOf(model.${field.name}$convert)
          : null
      ''';
    } else if (const TypeChecker.fromRuntime(Uint8List).isAssignableFromType(type)) {
      var convert = (field.type.nullabilitySuffix == NullabilitySuffix.question) ? '!' : '';
      serializedRepresentation = '''
        model.${field.name} != null ?
          base64.encode(model.${field.name}$convert)
          : null
      ''';
    }

    return serializedRepresentation;
  }

  bool _shouldPassToSuper(String paramName) {
    var superParams = {
      'idInt', 'firstname', 'lastname', 'age', 'gender', 'address',
      'email', 'photo', 'photo_id', 'authUser', 'createdAt', 'id', 'updatedAt'
    };
    return superParams.contains(paramName);
  }

  bool _isFieldBasedParameter(String paramName, BuildContext ctx) {
    return paramName.endsWith('_id') &&
        ctx.fields.any((f) => f.name == paramName.replaceAll('_id', ''));
  }

  String _getFieldForParameter(String paramName) {
    return paramName.replaceAll('_id', '');
  }

  List<ParameterElement> _collectAllConstructorParameters(BuildContext ctx) {
    var allParams = <ParameterElement>[];
    if (ctx.constructorParameters.isNotEmpty) {
      allParams.addAll(ctx.constructorParameters);
    }
    return allParams;
  }

  List<ParameterElement> _getInheritedParameters(BuildContext ctx, List<ParameterElement> allParams) {
    var inheritedParams = <ParameterElement>[];
    var inheritedFieldNames = {
      'idInt', 'firstname', 'lastname', 'age', 'gender', 'address',
      'email', 'photo', 'photo_id', 'authUser', 'createdAt', 'id'
    };

    for (var param in allParams) {
      if (inheritedFieldNames.contains(param.name)) {
        inheritedParams.add(param);
      }
    }

    return inheritedParams;
  }

  bool _isInheritedField(String fieldName, List<ParameterElement> inheritedParams) {
    return inheritedParams.any((param) => param.name == fieldName);
  }

  List<ParameterElement> _getAdditionalConstructorParameters(BuildContext ctx, List<ParameterElement> allParams) {
    var additionalParams = <ParameterElement>[];
    var currentFieldNames = ctx.fields.map((f) => f.name).toSet();
    var inheritedFieldNames = _getInheritedParameters(ctx, allParams).map((p) => p.name).toSet();

    for (var param in allParams) {
      if (!currentFieldNames.contains(param.name) && !inheritedFieldNames.contains(param.name)) {
        additionalParams.add(param);
      }
    }

    return additionalParams;
  }

  String _generateParameterValue(ParameterElement param, BuildContext ctx) {
    var paramType = param.type;
    var alias = ctx.resolveFieldName(param.name);
    var mapExtraction = "map['$alias']";

    if (paramType != null) {
      var typeStr = typeToString(paramType);
      if (paramType.nullabilitySuffix == NullabilitySuffix.question) {
        mapExtraction += ' as $typeStr?';
      } else {
        mapExtraction += ' as $typeStr';
      }
    }

    if (paramType != null && dateTimeTypeChecker.isAssignableFromType(paramType)) {
      return """${param.name} ?? (map['$alias'] != null ?
        (map['$alias'] is DateTime ?
          (map['$alias'] as DateTime) :
          DateTime.parse(map['$alias'].toString())) : null)""";
    } else if (paramType != null && isModelClass(paramType)) {
      var rc = ReCase(paramType.getDisplayString());
      return """${param.name} ?? (map['$alias'] != null ?
        ${rc.pascalCase.replaceAll('?', '')}Serializer.fromMap(map['$alias'] as Map) : null)""";
    } else {
      return '${param.name} ?? $mapExtraction';
    }
  }

  String _generateDeserializationForField(FieldElement field, BuildContext ctx) {
    var type = ctx.resolveSerializedFieldType(field.name);
    var alias = ctx.resolveFieldName(field.name);
    var deserializedRepresentation = "map['$alias']";

    var typeStr = typeToString(type);
    if (type.nullabilitySuffix == NullabilitySuffix.question) {
      deserializedRepresentation += ' as $typeStr?';
    } else {
      deserializedRepresentation += ' as $typeStr';
    }

    var defaultValue = 'null';
    var existingDefault = ctx.defaults[field.name];

    if (existingDefault != null) {
      var d = dartObjectToString(existingDefault);
      if (d != null) {
        defaultValue = d;
        if (!deserializedRepresentation.endsWith("?")) {
          deserializedRepresentation += "?";
        }
      }
      deserializedRepresentation = '$deserializedRepresentation ?? $defaultValue';
    }

    var fieldNameDeserializer = ctx.fieldInfo[field.name]?.deserializer;
    if (fieldNameDeserializer != null) {
      var name = MirrorSystem.getName(fieldNameDeserializer);
      return "$name(map['$alias'])";
    }

    if (dateTimeTypeChecker.isAssignableFromType(type)) {
      if (field.type.nullabilitySuffix != NullabilitySuffix.question) {
        if (defaultValue.toLowerCase() == 'null') {
          defaultValue = 'DateTime.parse("1970-01-01 00:00:00")';
        } else {
          defaultValue = 'DateTime.parse("$defaultValue")';
        }
      }
      return """map['$alias'] != null ?
        (map['$alias'] is DateTime ?
          (map['$alias'] as DateTime) :
          DateTime.parse(map['$alias'].toString())) : $defaultValue""";
    }

    if (isModelClass(type)) {
      var rc = ReCase(type.getDisplayString());
      return """map['$alias'] != null ?
        ${rc.pascalCase.replaceAll('?', '')}Serializer.fromMap(map['$alias'] as Map) : $defaultValue""";
    }

    if (type is InterfaceType) {
      if (isListOfModelType(type)) {
        if (defaultValue == 'null') defaultValue = '[]';
        var rc = ReCase(type.typeArguments[0].getDisplayString());
        return """map['$alias'] is Iterable ?
          List.unmodifiable(((map['$alias'] as Iterable).whereType<Map>())
            .map(${rc.pascalCase.replaceAll('?', '')}Serializer.fromMap)) : $defaultValue""";
      }

      if (isMapToModelType(type)) {
        if (defaultValue == 'null') defaultValue = '{}';
        var rc = ReCase(type.typeArguments[1].getDisplayString());
        return """map['$alias'] is Map ?
          Map.unmodifiable((map['$alias'] as Map).keys.fold({}, (out, key) {
            return out..[key] = ${rc.pascalCase.replaceAll('?', '')}Serializer
              .fromMap(((map['$alias'] as Map)[key]) as Map);
          })) : $defaultValue""";
      }

      if (type.element is Enum) {
        return """map['$alias'] is ${type.getDisplayString()} ?
          (map['$alias'] as ${type.getDisplayString()}) ?? $defaultValue :
          (map['$alias'] is int ?
            ${type.getDisplayString()}.values[map['$alias'] as int] : $defaultValue)""";
      }

      if (const TypeChecker.fromRuntime(List).isAssignableFromType(type) && type.typeArguments.length == 1) {
        if (defaultValue == 'null') defaultValue = '[]';
        var arg = convertTypeReference(type.typeArguments[0]).accept(DartEmitter(useNullSafetySyntax: true));
        return """map['$alias'] is Iterable ?
          (map['$alias'] as Iterable).cast<$arg>().toList() : $defaultValue""";
      }

      if (const TypeChecker.fromRuntime(Map).isAssignableFromType(type) && type.typeArguments.length == 2) {
        var key = convertTypeReference(type.typeArguments[0]).accept(DartEmitter(useNullSafetySyntax: true));
        var value = convertTypeReference(type.typeArguments[1]).accept(DartEmitter(useNullSafetySyntax: true));
        if (defaultValue == 'null') defaultValue = '{}';
        return """map['$alias'] is Map ?
          (map['$alias'] as Map).cast<$key, $value>() : $defaultValue""";
      }

      if (const TypeChecker.fromRuntime(Uint8List).isAssignableFromType(type)) {
        return """map['$alias'] is Uint8List ?
          (map['$alias'] as Uint8List) :
          (map['$alias'] is Iterable<int> ?
            Uint8List.fromList((map['$alias'] as Iterable<int>).toList()) :
            (map['$alias'] is String ?
              Uint8List.fromList(base64.decode(map['$alias'] as String)) : $defaultValue))""";
      }
    }

    return deserializedRepresentation;
  }
}
