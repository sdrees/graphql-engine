use std::collections::BTreeMap;

use open_dds::permissions::{
    FieldPreset, Role, TypeOutputPermission, TypePermissionsV1, ValueExpression,
};

use open_dds::types::{CustomTypeName, FieldName};

use crate::types::error::Error;

use crate::types::subgraph::Qualified;

use crate::helpers::typecheck;
use crate::stages::object_types;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct TypeInputPermission {
    pub field_presets: BTreeMap<FieldName, ValueExpression>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct ObjectTypeWithPermissions {
    pub object_type: object_types::ObjectTypeRepresentation,
    /// permissions on this type, when it is used in an output context (e.g. as
    /// a return type of Model or Command)
    pub type_output_permissions: BTreeMap<Role, TypeOutputPermission>,
    /// permissions on this type, when it is used in an input context (e.g. in
    /// an argument type of Model or Command)
    pub type_input_permissions: BTreeMap<Role, TypeInputPermission>,
    /// type mappings for each data connector
    pub type_mappings: object_types::DataConnectorTypeMappingsForObject,
}

/// resolve type permissions
pub fn resolve(
    metadata_accessor: &open_dds::accessor::MetadataAccessor,
    object_types: &BTreeMap<Qualified<CustomTypeName>, object_types::ObjectTypeWithTypeMappings>,
) -> Result<BTreeMap<Qualified<CustomTypeName>, ObjectTypeWithPermissions>, Error> {
    let mut object_types_with_permissions = BTreeMap::new();
    for (object_type_name, object_type) in object_types {
        object_types_with_permissions.insert(
            object_type_name.clone(),
            ObjectTypeWithPermissions {
                object_type: object_type.object_type.clone(),
                type_mappings: object_type.type_mappings.clone(),
                type_input_permissions: BTreeMap::new(),
                type_output_permissions: BTreeMap::new(),
            },
        );
    }

    // resolve type permissions
    for open_dds::accessor::QualifiedObject {
        subgraph,
        object: output_type_permission,
    } in &metadata_accessor.type_permissions
    {
        let qualified_type_name = Qualified::new(
            subgraph.to_string(),
            output_type_permission.type_name.to_owned(),
        );
        match object_types_with_permissions.get_mut(&qualified_type_name) {
            None => {
                return Err(Error::UnknownTypeInOutputPermissionsDefinition {
                    type_name: qualified_type_name,
                })
            }
            Some(object_type) => {
                object_type.type_output_permissions = resolve_output_type_permission(
                    &object_type.object_type,
                    output_type_permission,
                )?;
                object_type.type_input_permissions = resolve_input_type_permission(
                    &object_type.object_type,
                    output_type_permission,
                )?;
            }
        }
    }
    Ok(object_types_with_permissions)
}

pub fn resolve_output_type_permission(
    object_type_representation: &object_types::ObjectTypeRepresentation,
    type_permissions: &TypePermissionsV1,
) -> Result<BTreeMap<Role, TypeOutputPermission>, Error> {
    let mut resolved_type_permissions = BTreeMap::new();

    // validate all the fields definied in output permissions actually
    // exist in this type definition
    for type_permission in &type_permissions.permissions {
        if let Some(output) = &type_permission.output {
            for field_name in &output.allowed_fields {
                if !object_type_representation.fields.contains_key(field_name) {
                    return Err(Error::UnknownFieldInOutputPermissionsDefinition {
                        field_name: field_name.clone(),
                        type_name: type_permissions.type_name.clone(),
                    });
                }
            }
            if resolved_type_permissions
                .insert(type_permission.role.clone(), output.clone())
                .is_some()
            {
                return Err(Error::DuplicateOutputTypePermissions {
                    type_name: type_permissions.type_name.clone(),
                });
            }
        }
    }
    Ok(resolved_type_permissions)
}

pub(crate) fn resolve_input_type_permission(
    object_type_representation: &object_types::ObjectTypeRepresentation,
    type_permissions: &TypePermissionsV1,
) -> Result<BTreeMap<Role, TypeInputPermission>, Error> {
    let mut resolved_type_permissions = BTreeMap::new();

    for type_permission in &type_permissions.permissions {
        if let Some(input) = &type_permission.input {
            let mut resolved_field_presets = BTreeMap::new();
            for FieldPreset {
                field: field_name,
                value,
            } in &input.field_presets
            {
                // check if the field exists on this type
                match object_type_representation.fields.get(field_name) {
                    Some(field_definition) => {
                        // check if the value is provided typechecks
                        typecheck::typecheck_value_expression(&field_definition.field_type, value)
                            .map_err(|type_error| Error::FieldPresetTypeError {
                                field_name: field_name.clone(),
                                type_name: type_permissions.type_name.clone(),
                                type_error,
                            })?;
                    }
                    None => {
                        return Err(Error::UnknownFieldInInputPermissionsDefinition {
                            field_name: field_name.clone(),
                            type_name: type_permissions.type_name.clone(),
                        });
                    }
                }
                resolved_field_presets.insert(field_name.clone(), value.clone());
            }
            if resolved_type_permissions
                .insert(
                    type_permission.role.clone(),
                    TypeInputPermission {
                        field_presets: resolved_field_presets,
                    },
                )
                .is_some()
            {
                return Err(Error::DuplicateInputTypePermissions {
                    type_name: type_permissions.type_name.clone(),
                });
            }
        }
    }
    Ok(resolved_type_permissions)
}
