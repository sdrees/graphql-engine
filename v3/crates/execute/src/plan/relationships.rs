//! NDC query generation from 'ModelSelection' IR for relationships.

use open_dds::relationships::RelationshipType;
use std::collections::BTreeMap;

use super::selection_set;
use crate::ir::model_selection::ModelSelection;
use crate::ir::relationship::{self, LocalCommandRelationshipInfo, LocalModelRelationshipInfo};
use crate::ir::selection_set::FieldSelection;
use crate::plan::error;

/// collect relationships recursively from IR components containing relationships,
/// and create NDC relationship definitions which will be added to the `relationships`
/// variable.
pub(crate) fn collect_relationships(
    ir: &ModelSelection<'_>,
    relationships: &mut BTreeMap<ndc_models::RelationshipName, ndc_models::Relationship>,
) -> Result<(), error::Error> {
    // from selection fields
    if let Some(selection) = &ir.selection {
        for field in selection.fields.values() {
            match field {
                FieldSelection::ModelRelationshipLocal {
                    query,
                    name,
                    relationship_info,
                } => {
                    relationships.insert(
                        ndc_models::RelationshipName::from(name.0.as_str()),
                        process_model_relationship_definition(relationship_info)?,
                    );
                    collect_relationships(query, relationships)?;
                }
                FieldSelection::CommandRelationshipLocal {
                    ir,
                    name,
                    relationship_info,
                } => {
                    relationships.insert(
                        ndc_models::RelationshipName::from(name.0.as_str()),
                        process_command_relationship_definition(relationship_info)?,
                    );
                    if let Some(nested_selection) = &ir.command_info.selection {
                        selection_set::collect_relationships_from_nested_selection(
                            nested_selection,
                            relationships,
                        )?;
                    }
                }
                FieldSelection::Column { .. }
                // we ignore remote relationships as we are generating relationship
                // definition for one data connector
                | FieldSelection::ModelRelationshipRemote { .. }
                | FieldSelection::CommandRelationshipRemote { .. } => (),
            };
        }
    }

    // from order by clause
    if let Some(order_by) = &ir.order_by {
        for (name, relationship) in &order_by.relationships {
            let result = process_model_relationship_definition(relationship)?;
            relationships.insert(ndc_models::RelationshipName::from(name.0.as_str()), result);
        }
    };

    Ok(())
}

pub fn process_model_relationship_definition(
    relationship_info: &LocalModelRelationshipInfo,
) -> Result<ndc_models::Relationship, error::Error> {
    let &LocalModelRelationshipInfo {
        relationship_name,
        relationship_type,
        source_type,
        source_data_connector,
        source_type_mappings,
        target_source,
        target_type: _,
        mappings,
    } = relationship_info;

    let mut column_mapping = BTreeMap::new();
    for metadata_resolve::RelationshipModelMapping {
        source_field: source_field_path,
        target_field: _,
        target_ndc_column,
    } in mappings
    {
        if matches!(
            metadata_resolve::relationship_execution_category(
                source_data_connector,
                &target_source.model.data_connector,
                &target_source.capabilities
            ),
            metadata_resolve::RelationshipExecutionCategory::Local
        ) {
            let target_column = target_ndc_column.as_ref().ok_or_else(|| {
                error::InternalError::InternalGeneric {
                    description: format!(
                        "No column mapping for relationship {relationship_name} on {source_type}"
                    ),
                }
            })?;

            let source_column = relationship::get_field_mapping_of_field_name(
                source_type_mappings,
                source_type,
                relationship_name,
                &source_field_path.field_name,
            )
            .map_err(|e| error::InternalError::InternalGeneric {
                description: e.to_string(),
            })?;

            if column_mapping
                .insert(
                    ndc_models::FieldName::from(source_column.column.as_str()),
                    ndc_models::FieldName::from(target_column.column.as_str()),
                )
                .is_some()
            {
                Err(error::InternalError::MappingExistsInRelationship {
                    source_column: source_field_path.field_name.clone(),
                    relationship_name: relationship_name.clone(),
                })?;
            }
        } else {
            Err(error::InternalError::RemoteRelationshipsAreNotSupported)?;
        }
    }
    let ndc_relationship = ndc_models::Relationship {
        column_mapping,
        relationship_type: {
            match relationship_type {
                RelationshipType::Object => ndc_models::RelationshipType::Object,
                RelationshipType::Array => ndc_models::RelationshipType::Array,
            }
        },
        target_collection: ndc_models::CollectionName::from(
            target_source.model.collection.as_str(),
        ),
        arguments: BTreeMap::new(),
    };
    Ok(ndc_relationship)
}

pub(crate) fn process_command_relationship_definition(
    relationship_info: &LocalCommandRelationshipInfo,
) -> Result<ndc_models::Relationship, error::Error> {
    let &LocalCommandRelationshipInfo {
        annotation,
        source_data_connector,
        source_type_mappings,
        target_source,
    } = relationship_info;

    let mut arguments = BTreeMap::new();
    for metadata_resolve::RelationshipCommandMapping {
        source_field: source_field_path,
        argument_name: target_argument,
    } in &annotation.mappings
    {
        if matches!(
            metadata_resolve::relationship_execution_category(
                source_data_connector,
                &target_source.details.data_connector,
                &target_source.capabilities
            ),
            metadata_resolve::RelationshipExecutionCategory::Local
        ) {
            let source_column = relationship::get_field_mapping_of_field_name(
                source_type_mappings,
                &annotation.source_type,
                &annotation.relationship_name,
                &source_field_path.field_name,
            )
            .map_err(|e| error::InternalError::InternalGeneric {
                description: e.to_string(),
            })?;

            let relationship_argument = ndc_models::RelationshipArgument::Column {
                name: ndc_models::FieldName::from(source_column.column.as_str()),
            };

            let connector_argument_name = target_source
                .details
                .argument_mappings
                .get(target_argument)
                .ok_or_else(|| {
                    error::Error::Internal(
                        error::InternalError::MissingArgumentMappingInCommandRelationship {
                            source_type: annotation.source_type.clone(),
                            relationship_name: annotation.relationship_name.clone(),
                            command_name: annotation.command_name.clone(),
                            argument_name: target_argument.clone(),
                        },
                    )
                })?;

            if arguments
                .insert(
                    ndc_models::ArgumentName::from(connector_argument_name.as_str()),
                    relationship_argument,
                )
                .is_some()
            {
                Err(error::InternalError::MappingExistsInRelationship {
                    source_column: source_field_path.field_name.clone(),
                    relationship_name: annotation.relationship_name.clone(),
                })?;
            }
        } else {
            Err(error::InternalError::RemoteRelationshipsAreNotSupported)?;
        }
    }

    let ndc_relationship = ndc_models::Relationship {
        column_mapping: BTreeMap::new(),
        relationship_type: ndc_models::RelationshipType::Object,
        target_collection: ndc_models::CollectionName::from(target_source.function_name.as_str()),
        arguments,
    };
    Ok(ndc_relationship)
}
