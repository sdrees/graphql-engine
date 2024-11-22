use crate::error;
use open_dds::{commands::ProcedureName, types::DataConnectorArgumentName};
use plan_types::{NdcRelationshipName, Relationship};
use std::collections::BTreeMap;
use std::sync::Arc;

use super::arguments;
use super::field;
use super::filter::ResolveFilterExpressionContext;

pub type UnresolvedMutationExecutionPlan<'s> = MutationExecutionPlan<'s>;

#[derive(Debug)]
pub struct MutationExecutionPlan<'s> {
    /// The name of a procedure
    pub procedure_name: ProcedureName,
    /// Any named procedure arguments
    pub procedure_arguments: BTreeMap<DataConnectorArgumentName, arguments::MutationArgument<'s>>,
    /// The fields to return from the result, or null to return everything
    pub procedure_fields: Option<field::NestedField<'s>>,
    /// Any relationships between collections involved in the query request
    pub collection_relationships: BTreeMap<NdcRelationshipName, Relationship>,
    /// The data connector used to fetch the data
    pub data_connector: Arc<metadata_resolve::DataConnectorLink>,
}

impl<'s> MutationExecutionPlan<'s> {
    pub async fn resolve(
        self,
        resolve_context: &'s ResolveFilterExpressionContext<'_>,
    ) -> Result<plan_types::MutationExecutionPlan, error::FieldError> {
        let MutationExecutionPlan {
            procedure_name,
            procedure_arguments,
            procedure_fields,
            collection_relationships,
            data_connector,
        } = self;

        let resolved_fields = match procedure_fields {
            Some(fields) => Some(fields.resolve(resolve_context).await?),
            None => None,
        };

        let resolved_arguments =
            arguments::resolve_mutation_arguments(resolve_context, procedure_arguments).await?;

        Ok(plan_types::MutationExecutionPlan {
            procedure_name,
            procedure_arguments: resolved_arguments,
            procedure_fields: resolved_fields,
            collection_relationships,
            data_connector,
        })
    }
}
