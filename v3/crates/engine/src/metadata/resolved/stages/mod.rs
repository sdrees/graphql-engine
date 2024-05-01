mod apollo;
pub mod boolean_expressions;
pub mod command_permissions;
pub mod commands;
/// This is where we'll be moving explicit metadata resolve stages
pub mod data_connector_scalar_types;
pub mod data_connectors;
pub mod graphql_config;
pub mod model_permissions;
pub mod models;
pub mod object_types;
pub mod relationships;
pub mod roles;
pub mod scalar_types;
pub mod type_permissions;
mod types;

pub use types::Metadata;

use crate::metadata::resolved::types::error::Error;

/// this is where we take the input metadata and attempt to resolve a working `Metadata` object
/// currently the bulk of this lives in the `resolve_metadata` function, we'll be slowly breaking
/// it up and moving it into steps here
pub fn resolve(metadata: open_dds::Metadata) -> Result<Metadata, Error> {
    let metadata_accessor: open_dds::accessor::MetadataAccessor =
        open_dds::accessor::MetadataAccessor::new(metadata);

    let graphql_config =
        graphql_config::resolve(&metadata_accessor.graphql_config, &metadata_accessor.flags)?;

    let data_connectors = data_connectors::resolve(&metadata_accessor)?;

    let object_types::DataConnectorTypeMappingsOutput {
        graphql_types,
        global_id_enabled_types,
        apollo_federation_entity_enabled_types,
        object_types,
    } = object_types::resolve(&metadata_accessor, &data_connectors)?;

    let scalar_types::ScalarTypesOutput {
        scalar_types,
        graphql_types,
    } = scalar_types::resolve(&metadata_accessor, &graphql_types)?;

    let data_connector_scalar_types::DataConnectorWithScalarsOutput {
        data_connectors,
        graphql_types,
    } = data_connector_scalar_types::resolve(
        &metadata_accessor,
        &data_connectors,
        &scalar_types,
        &graphql_types,
    )?;

    let object_types_with_permissions =
        type_permissions::resolve(&metadata_accessor, &object_types)?;

    let boolean_expressions::BooleanExpressionsOutput {
        boolean_expression_types,
        graphql_types,
    } = boolean_expressions::resolve(
        &metadata_accessor,
        &data_connectors,
        &object_types_with_permissions,
        &scalar_types,
        &graphql_types,
        &graphql_config,
    )?;

    let models::ModelsOutput {
        models,
        global_id_enabled_types,
        apollo_federation_entity_enabled_types,
        graphql_types: _graphql_types,
    } = models::resolve(
        &metadata_accessor,
        &data_connectors,
        &graphql_types,
        &global_id_enabled_types,
        &apollo_federation_entity_enabled_types,
        &object_types_with_permissions,
        &scalar_types,
        &boolean_expression_types,
        &graphql_config,
    )?;

    let commands = commands::resolve(
        &metadata_accessor,
        &data_connectors,
        &object_types_with_permissions,
        &scalar_types,
        &boolean_expression_types,
    )?;

    apollo::resolve(
        &global_id_enabled_types,
        &apollo_federation_entity_enabled_types,
    )?;

    let object_types_with_relationships = relationships::resolve(
        &metadata_accessor,
        &data_connectors,
        &object_types_with_permissions,
        &models,
        &commands,
    )?;

    let commands_with_permissions = command_permissions::resolve(
        &metadata_accessor,
        &commands,
        &object_types_with_relationships,
        &boolean_expression_types,
        &data_connectors,
    )?;

    let models_with_permissions = model_permissions::resolve(
        &metadata_accessor,
        &data_connectors,
        &object_types_with_relationships,
        &models,
        &boolean_expression_types,
    )?;

    let roles = roles::resolve(
        &object_types_with_relationships,
        &models_with_permissions,
        &commands_with_permissions,
    );

    Ok(Metadata {
        scalar_types,
        object_types: object_types_with_relationships,
        models: models_with_permissions,
        commands: commands_with_permissions,
        boolean_expression_types,
        graphql_config: graphql_config.global,
        roles,
    })
}
