use std::collections::HashMap;

use open_dds::{models::ModelName, types::CustomTypeName};

use crate::metadata::resolved::types::error::Error;

use crate::metadata::resolved::types::subgraph::Qualified;

/// This isn't a particularly satisfying resolve step, as it only serves to validate
/// the output of previous steps.
/// Ideally, we could move more Apollo-based resolving into this discreet step, haven't
/// investigated this too deeply yet.
pub fn resolve(
    global_id_enabled_types: &HashMap<Qualified<CustomTypeName>, Vec<Qualified<ModelName>>>,
    apollo_federation_entity_enabled_types: &HashMap<
        Qualified<CustomTypeName>,
        Option<Qualified<open_dds::models::ModelName>>,
    >,
) -> Result<(), Error> {
    // To check if global_id_fields are defined in object type but no model has global_id_source set to true:
    //   - Throw an error if no model with globalIdSource:true is found for the object type.
    for (object_type, model_name_list) in global_id_enabled_types {
        if model_name_list.is_empty() {
            return Err(Error::GlobalIdSourceNotDefined {
                object_type: object_type.clone(),
            });
        }
    }

    // To check if apollo federation entity keys are defined in object type but no model has
    // apollo_federation_entity_source set to true:
    //   - Throw an error if no model with apolloFederation.entitySource:true is found for the object type.
    for (object_type, model_name_list) in apollo_federation_entity_enabled_types {
        if model_name_list.is_none() {
            return Err(Error::ApolloFederationEntitySourceNotDefined {
                object_type: object_type.clone(),
            });
        }
    }
    Ok(())
}
