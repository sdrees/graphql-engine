//! internal feature flags exposed with `UNSTABLE_FEATURES` environment variable

/// Set of features in development that we want to switch on in development
/// If we want to start offering user control of these, they should move out of here and into the
/// flags in Metadata, nothing here should be depended on.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, clap::ValueEnum, serde::Deserialize,
)]
#[serde(rename_all = "snake_case")]
pub enum UnstableFeature {
    EnableBooleanExpressionTypes,
    EnableOrderByExpressions,
    EnableNdcV02Support,
}

pub fn resolve_unstable_features(
    unstable_features: &[UnstableFeature],
) -> metadata_resolve::configuration::UnstableFeatures {
    let mut features = metadata_resolve::configuration::UnstableFeatures::default();

    for unstable_feature in unstable_features {
        match unstable_feature {
            UnstableFeature::EnableBooleanExpressionTypes => {
                features.enable_boolean_expression_types = true;
            }
            UnstableFeature::EnableOrderByExpressions => {
                features.enable_order_by_expressions = true;
            }
            UnstableFeature::EnableNdcV02Support => {
                features.enable_ndc_v02_support = true;
            }
        }
    }

    features
}
