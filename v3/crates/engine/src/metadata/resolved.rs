mod argument;
pub mod error;
pub mod metadata;
pub mod model;
pub mod ndc_validation;
pub mod permission;
pub mod stages;
pub mod subgraph;
mod typecheck;
pub mod types;

/// ideally none of the above will be public, and only types needed downstream will be explicitly
/// exported here. that way other modules don't know the internal structure of this `validate`
/// section and we can move things around without changing the whole codebase.
pub use stages::boolean_expressions::{
    BooleanExpressionInfo, ComparisonExpressionInfo, ObjectBooleanExpressionType,
};
pub use stages::command_permissions::CommandWithPermissions;
pub use stages::commands::Command;
pub use stages::data_connector_type_mappings::{FieldMapping, TypeMapping};
pub use stages::models::{
    FilterPermission, Model, ModelOrderByExpression, ModelPredicate, ModelSource,
    SelectManyGraphQlDefinition, SelectUniqueGraphQlDefinition,
};
/// we seem to be exporting functions. perhaps these would be better served as methods on the data
/// types we export?
pub use stages::relationships::{
    relationship_execution_category, ObjectTypeWithRelationships, Relationship,
    RelationshipCapabilities, RelationshipCommandMapping, RelationshipExecutionCategory,
    RelationshipModelMapping, RelationshipTarget,
};
pub use stages::resolve;
