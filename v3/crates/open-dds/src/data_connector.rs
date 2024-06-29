use ndc_models;
use ndc_models_v01;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

mod v1;

pub use v1::{
    ArgumentPreset, ArgumentPresetValue, DataConnectorLinkV1,
    DataConnectorUrlV1 as DataConnectorUrl, HttpHeadersPreset, ReadWriteUrls, ResponseHeaders,
};

use crate::{identifier::Identifier, impl_OpenDd_default_for};

/// The name of a data connector.
#[derive(
    Serialize,
    Deserialize,
    Clone,
    Debug,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    JsonSchema,
    derive_more::Display,
    opendds_derive::OpenDd,
)]
pub struct DataConnectorName(pub Identifier);

/// The name of an object type in a data connector.
#[repr(transparent)]
#[derive(
    Serialize,
    Deserialize,
    Clone,
    Debug,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    JsonSchema,
    ref_cast::RefCast,
    derive_more::Display,
    opendds_derive::OpenDd,
)]
pub struct DataConnectorObjectType(pub String);

/// The name of a scalar type in a data connector.
#[repr(transparent)]
#[derive(
    Serialize,
    Deserialize,
    Clone,
    Debug,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    JsonSchema,
    ref_cast::RefCast,
    derive_more::Display,
    opendds_derive::OpenDd,
)]
pub struct DataConnectorScalarType(pub String);

/// The name of an operator in a data connector.
#[repr(transparent)]
#[derive(
    Serialize,
    Deserialize,
    Clone,
    Debug,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    JsonSchema,
    ref_cast::RefCast,
    derive_more::Display,
    opendds_derive::OpenDd,
)]
pub struct DataConnectorOperatorName(pub String);

/// The name of a column in a data connector.
#[repr(transparent)]
#[derive(
    Serialize,
    Deserialize,
    Clone,
    Debug,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    JsonSchema,
    ref_cast::RefCast,
    derive_more::Display,
    opendds_derive::OpenDd,
)]
pub struct DataConnectorColumnName(pub String);

#[derive(Serialize, Clone, Debug, PartialEq, opendds_derive::OpenDd)]
#[serde(tag = "version", content = "definition")]
#[serde(rename_all = "camelCase")]
#[opendd(
    as_versioned_with_definition,
    json_schema(title = "DataConnectorLink", example = "DataConnectorLink::example")
)]
/// Definition of a data connector, used to bring in sources of data and connect them to OpenDD models and commands.
pub enum DataConnectorLink {
    V1(DataConnectorLinkV1),
}

impl DataConnectorLink {
    fn example() -> serde_json::Value {
        serde_json::json!({
            "kind": "DataConnectorLink",
            "version": "v1",
            "definition": {
                "name": "data_connector",
                "url": {
                    "singleUrl": {
                        "value": "http://data_connector:8100"
                    }
                },
                "headers": {},
                "schema": {
                    "version": "v0.1",
                    "schema": {
                        "scalar_types": {},
                        "object_types": {},
                        "collections": [],
                        "functions": [],
                        "procedures": []
                    },
                    "capabilities": {
                        "version": "0.1.3",
                        "capabilities": {
                            "query": {
                                "nested_fields": {},
                                "variables": {}
                            },
                            "mutation": {}
                        }
                    },
                }
            }
        })
    }

    pub fn upgrade(self) -> DataConnectorLinkV1 {
        match self {
            DataConnectorLink::V1(v1) => v1,
        }
    }
}

fn ndc_capabilities_response_v01_schema_reference(
    _gen: &mut schemars::gen::SchemaGenerator,
) -> schemars::schema::Schema {
    schemars::schema::Schema::new_ref("https://raw.githubusercontent.com/hasura/ndc-spec/v0.1.4/ndc-models/tests/json_schema/capabilities_response.jsonschema".into())
}

fn ndc_schema_response_v01_schema_reference(
    _gen: &mut schemars::gen::SchemaGenerator,
) -> schemars::schema::Schema {
    schemars::schema::Schema::new_ref("https://raw.githubusercontent.com/hasura/ndc-spec/v0.1.4/ndc-models/tests/json_schema/schema_response.jsonschema".into())
}

fn ndc_capabilities_response_v02_schema_reference(
    _gen: &mut schemars::gen::SchemaGenerator,
) -> schemars::schema::Schema {
    schemars::schema::Schema::new_ref("https://raw.githubusercontent.com/hasura/ndc-spec/main/ndc-models/tests/json_schema/capabilities_response.jsonschema".into())
}

fn ndc_schema_response_v02_schema_reference(
    _gen: &mut schemars::gen::SchemaGenerator,
) -> schemars::schema::Schema {
    schemars::schema::Schema::new_ref("https://raw.githubusercontent.com/hasura/ndc-spec/main/ndc-models/tests/json_schema/schema_response.jsonschema".into())
}

#[derive(Serialize, Clone, Debug, PartialEq, opendds_derive::OpenDd)]
#[serde(tag = "version")]
#[serde(rename_all = "camelCase")]
#[opendd(
    as_versioned_internally_tagged,
    json_schema(title = "VersionedSchemaAndCapabilities")
)]
pub enum VersionedSchemaAndCapabilities {
    #[serde(rename = "v0.1")]
    #[opendd(rename = "v0.1")]
    V01(SchemaAndCapabilitiesV01),
    #[serde(rename = "v0.2")]
    #[opendd(rename = "v0.2", hidden)]
    V02(SchemaAndCapabilitiesV02),
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[serde(deny_unknown_fields)]
#[schemars(title = "SchemaAndCapabilitiesV01")]
pub struct SchemaAndCapabilitiesV01 {
    #[schemars(schema_with = "ndc_schema_response_v01_schema_reference")]
    pub schema: ndc_models_v01::SchemaResponse,
    #[schemars(schema_with = "ndc_capabilities_response_v01_schema_reference")]
    pub capabilities: ndc_models_v01::CapabilitiesResponse,
}

// Derive OpenDd for `SchemaAdnCapabilitiesV01` by serde Deserialize and schemars JsonSchema implementations.
impl_OpenDd_default_for!(SchemaAndCapabilitiesV01);

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[serde(deny_unknown_fields)]
#[schemars(title = "SchemaAndCapabilitiesV01")]
pub struct SchemaAndCapabilitiesV02 {
    #[schemars(schema_with = "ndc_schema_response_v02_schema_reference")]
    pub schema: ndc_models::SchemaResponse,
    #[schemars(schema_with = "ndc_capabilities_response_v02_schema_reference")]
    pub capabilities: ndc_models::CapabilitiesResponse,
}

// Derive OpenDd for `SchemaAdnCapabilitiesV02` by serde Deserialize and schemars JsonSchema implementations.
impl_OpenDd_default_for!(SchemaAndCapabilitiesV02);

#[cfg(test)]
mod tests {
    use super::DataConnectorLinkV1;
    use crate::data_connector::DataConnectorLink;

    #[test]
    fn test_upgrade() {
        let v1: DataConnectorLink = crate::traits::OpenDd::deserialize(serde_json::json!(
            {
                "version": "v1",
                "definition": {
                    "name": "foo",
                    "url": {
                        "singleUrl": {
                            "value": "http://foo"
                        }
                    },
                    "headers": {
                        "Authorization": {
                            "value": "Bearer: abc"
                        }
                    },
                    "schema": {
                        "version": "v0.1",
                        "capabilities": {
                            "version": "0.1.3",
                            "capabilities": {
                                "query": {
                                    "nested_fields": {}
                                },
                                "mutation": {}
                            }
                        },
                        "schema": {
                            "scalar_types": {},
                            "object_types": {},
                            "collections": [],
                            "functions": [],
                            "procedures": []
                        }
                    }
                }
            }
        ))
        .unwrap();

        let upgraded: DataConnectorLinkV1 = crate::traits::OpenDd::deserialize(serde_json::json!(
            {
                "name": "foo",
                "url": {
                    "singleUrl": {
                        "value": "http://foo"
                    }
                },
                "headers": {
                    "Authorization": {
                        "value": "Bearer: abc"
                    }
                },
                "schema": {
                    "version": "v0.1",
                    "capabilities": {
                        "version": "0.1.3",
                        "capabilities": {
                            "query": {
                              "nested_fields": {}
                            },
                            "mutation": {}
                        }
                    },
                    "schema": {
                        "scalar_types": {},
                        "object_types": {},
                        "collections": [],
                        "functions": [],
                        "procedures": []
                    }
                }
            }
        ))
        .unwrap();

        assert_eq!(v1.upgrade(), upgraded);
    }
}
