// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:flutter_data/flutter_data.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_helper/source_helper.dart';

import 'utils.dart';

Builder repositoryBuilder(options) =>
    SharedPartBuilder([RepositoryGenerator()], 'flutter_data');

class RepositoryGenerator extends GeneratorForAnnotation<DataRepository> {
  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    final className = element.name!;
    final classNameLower = DataHelpers.internalTypeFor(className);
    ClassElement classElement;

    try {
      classElement = element as ClassElement;
    } catch (e) {
      throw UnsupportedError(
          "Can't generate repository for $className. Please use @DataRepository on a class.");
    }

    final annot = TypeChecker.fromRuntime(JsonSerializable);

    var fieldRename = annot
        .firstAnnotationOfExact(classElement, throwOnUnresolved: false)
        ?.getField('fieldRename');
    if (fieldRename == null && classElement.freezedConstructor != null) {
      fieldRename = annot
          .firstAnnotationOfExact(classElement.freezedConstructor!,
              throwOnUnresolved: false)
          ?.getField('fieldRename');
    }

    void _checkIsFinal(final InterfaceElement? element, String? name) {
      if (element != null) {
        if (name != null &&
            element.getSetter(name) != null &&
            !element.getField(name)!.isLate) {
          throw UnsupportedError(
              "Can't generate repository for $className. The `$name` field MUST be final");
        }
        _checkIsFinal(element.supertype?.element, name);
      }
    }

    _checkIsFinal(classElement, 'id');

    for (final field in classElement.relationshipFields) {
      _checkIsFinal(classElement, field.name);
    }

    // relationship-related

    final relationships = classElement.relationshipFields
        .fold<Set<Map<String, String?>>>({}, (result, field) {
      final relationshipClassElement = field.typeElement;

      final relationshipAnnotation = TypeChecker.fromRuntime(DataRelationship)
          .firstAnnotationOfExact(field, throwOnUnresolved: false);
      final jsonKeyAnnotation = TypeChecker.fromRuntime(JsonKey)
          .firstAnnotationOfExact(field, throwOnUnresolved: false);

      final jsonKeyIgnored =
          jsonKeyAnnotation?.getField('ignore')?.toBoolValue() ?? false;

      if (jsonKeyIgnored) {
        throw UnsupportedError('''
@JsonKey(ignore: true) is not allowed in Flutter Data relationships.

Please use @DataRelationship(serialized: false) to prevent it from
serializing and deserializing.
''');
      }

      // try again with @DataRelationship
      final serialize =
          relationshipAnnotation?.getField('serialize')?.toBoolValue() ?? true;

      // define inverse

      var inverse =
          relationshipAnnotation?.getField('inverse')?.toStringValue();

      if (inverse == null) {
        final possibleInverseElements =
            relationshipClassElement.relationshipFields.where((elem) {
          return (elem.type as ParameterizedType)
                  .typeArguments
                  .single
                  .element ==
              classElement;
        });

        if (possibleInverseElements.length > 1) {
          throw UnsupportedError('''
Too many possible inverses for relationship `${field.name}`
of type $className: ${possibleInverseElements.map((e) => e.name).join(', ')}

Please specify the correct inverse in the $className class, for example:

@DataRelationship(inverse: '${possibleInverseElements.first.name}')
final BelongsTo<${relationshipClassElement.name}> ${field.name};

and execute a code generation build again.
''');
        } else if (possibleInverseElements.length == 1) {
          inverse = possibleInverseElements.single.name;
        }
      }

      // prepare metadata

      // try to guess correct key name in json_serializable
      var keyName = jsonKeyAnnotation?.getField('name')?.toStringValue();

      if (keyName == null && fieldRename != null) {
        final fieldCase = fieldRename.getField('_name')?.toStringValue();
        switch (fieldCase) {
          case 'kebab':
            keyName = field.name.kebab;
            break;
          case 'snake':
            keyName = field.name.snake;
            break;
          case 'pascal':
            keyName = field.name.pascal;
            break;
          case 'none':
            keyName = field.name;
            break;
          default:
        }
      }

      keyName ??= field.name;

      result.add({
        'key': keyName,
        'name': field.name,
        'inverseName': inverse,
        'kind': field.type.element?.name,
        'type': relationshipClassElement.name,
        if (!serialize) 'serialize': 'false',
      });

      return result;
    }).toList();

    final relationshipMeta = {
      for (final rel in relationships)
        '\'${rel['key']}\'': '''RelationshipMeta<${rel['type']}>(
            name: '${rel['name']}',
            ${rel['inverseName'] != null ? 'inverseName: \'${rel['inverseName']}\',' : ''}
            type: '${DataHelpers.internalTypeFor(rel['type']!)}',
            kind: '${rel['kind']}',
            ${rel['serialize'] != null ? 'serialize: ${rel['serialize']},' : ''}
            instance: (_) => (_ as $className).${rel['name']},
          )''',
    };

    final relationshipGraphNodeExtension = {
      for (final rel in relationships)
        '''
RelationshipGraphNode<${rel['type']}> get ${rel['name']} {
  final meta = \$${className}LocalAdapter._k${className}RelationshipMetas['${rel['key']}']
      as RelationshipMeta<${rel['type']}>;
  return meta.clone(parent: this is RelationshipMeta ? this as RelationshipMeta : null);
}
'''
    };

    // serialization-related

    final hasFromJson =
        classElement.constructors.any((c) => c.name == 'fromJson');
    final fromJson = hasFromJson
        ? '$className.fromJson(map)'
        : '_\$${className}FromJson(map)';

    final methods = [
      ...classElement.methods,
      ...classElement.interfaces.map((i) => i.methods).expand((i) => i),
      ...classElement.mixins.map((i) => i.methods).expand((i) => i)
    ];
    final hasToJson = methods.any((c) => c.name == 'toJson');
    final toJson =
        hasToJson ? 'model.toJson()' : '_\$${className}ToJson(model)';

    // additional adapters

    final finders = <String>[];

    final mixins = annotation.read('adapters').listValue.map((obj) {
      final mixinType = obj.toTypeValue() as ParameterizedType;
      final mixinMethods = <MethodElement>[];
      String displayName;

      final args = mixinType.typeArguments;

      if (args.length > 1) {
        throw UnsupportedError(
            'Adapter `$mixinType` MUST have at most one type argument (T extends DataModel<T>) is supported for $mixinType');
      }

      // TODO this stopped working, restore
      // final remoteAdapterTypeChecker = TypeChecker.fromRuntime(RemoteAdapter);
      // if (!remoteAdapterTypeChecker
      //     .isAssignableFromType(mixinType)) {
      //   throw UnsupportedError(
      //       'Adapter `$mixinType` MUST have a constraint `on` RemoteAdapter<$className>');
      // }

      final instantiatedMixinType = (mixinType.element as MixinElement)
          .instantiate(
              typeArguments: [if (args.isNotEmpty) classElement.thisType],
              nullabilitySuffix: NullabilitySuffix.none);
      mixinMethods.addAll(instantiatedMixinType.methods);
      displayName =
          instantiatedMixinType.getDisplayString(withNullability: false);

      // add finders
      for (final field in mixinMethods) {
        final hasFinderAnnotation =
            TypeChecker.fromRuntime(DataFinder).hasAnnotationOfExact(field);
        if (hasFinderAnnotation) {
          finders.add(field.name);
        }
      }

      return displayName;
    }).toSet();

    final mixinShortcuts = mixins.map((mixin) {
      final mixinB = mixin.replaceAll(RegExp('<.*?>'), '').decapitalize();
      return '$mixin get $mixinB => remoteAdapter as $mixin;';
    }).join('\n');

    if (mixins.isEmpty) {
      mixins.add('NothingMixin');
    }

    final typeIdReader = annotation.read('typeId');
    final typeId = typeIdReader.isNull ? null : typeIdReader.intValue;

    // template

    return '''
// ignore_for_file: non_constant_identifier_names, duplicate_ignore

mixin \$${className}LocalAdapter on LocalAdapter<$className> {
  static final Map<String, RelationshipMeta> _k${className}RelationshipMetas = 
    $relationshipMeta;

  @override
  Map<String, RelationshipMeta> get relationshipMetas => _k${className}RelationshipMetas;

  @override
  $className deserialize(map) {
    map = transformDeserialize(map);
    return $fromJson;
  }

  @override
  Map<String, dynamic> serialize(model, {bool withRelationships = true}) {
    final map = $toJson;
    return transformSerialize(map, withRelationships: withRelationships);
  }
}

final _${classNameLower}Finders = <String, dynamic>{
  ${finders.map((f) => '''  '$f': (_) => _.$f,''').join('\n')}
};

// ignore: must_be_immutable
class \$${className}HiveLocalAdapter = HiveLocalAdapter<$className> with \$${className}LocalAdapter;

class \$${className}RemoteAdapter = RemoteAdapter<$className> with ${mixins.join(', ')};

final internal${classNameLower.capitalize()}RemoteAdapterProvider =
    Provider<RemoteAdapter<$className>>(
        (ref) => \$${className}RemoteAdapter(\$${className}HiveLocalAdapter(ref${typeId != null ? ', typeId: $typeId' : ''}), InternalHolder(_${classNameLower}Finders)));

final ${classNameLower}RepositoryProvider =
    Provider<Repository<$className>>((ref) => Repository<$className>(ref));

extension ${className}DataRepositoryX on Repository<$className> {
$mixinShortcuts
}

extension ${className}RelationshipGraphNodeX on RelationshipGraphNode<$className> {
  ${relationshipGraphNodeExtension.join('\n')}
}
''';
  }
}
