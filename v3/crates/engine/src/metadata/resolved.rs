//! no modules outside this should know about it's internal structure
mod helpers;
mod stages;
mod types;

pub use helpers::ndc_validation::NDCValidationError;
pub use helpers::types::{
    get_type_representation, mk_name, object_type_exists, unwrap_custom_type_name,
    NdcColumnForComparison, TypeRepresentation,
};
pub use stages::boolean_expressions::{
    BooleanExpressionInfo, ComparisonExpressionInfo, ObjectBooleanExpressionType,
};
pub use stages::command_permissions::CommandWithPermissions;
pub use stages::commands::Command;
pub use stages::data_connector_type_mappings::{
    FieldMapping, ObjectTypeRepresentation, ResolvedObjectApolloFederationConfig, TypeMapping,
};
pub use stages::data_connectors::DataConnectorLink;
pub use stages::model_permissions::{FilterPermission, ModelPredicate, ModelWithPermissions};
pub use stages::models::{
    Model, ModelOrderByExpression, ModelSource, SelectManyGraphQlDefinition,
    SelectUniqueGraphQlDefinition,
};
pub use stages::relationships::{
    relationship_execution_category, ObjectTypeWithRelationships, Relationship,
    RelationshipCapabilities, RelationshipCommandMapping, RelationshipExecutionCategory,
    RelationshipModelMapping, RelationshipTarget,
};
pub use stages::type_permissions::TypeInputPermission;
pub use stages::{resolve, Metadata};
pub use types::error::{BooleanExpressionError, Error};
pub use types::permission::ValueExpression;
pub use types::subgraph::{
    deserialize_non_string_key_btreemap, deserialize_qualified_btreemap,
    serialize_non_string_key_btreemap, serialize_qualified_btreemap, ArgumentInfo, Qualified,
    QualifiedBaseType, QualifiedTypeName, QualifiedTypeReference,
};
