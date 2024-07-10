use crate::stages::model_permissions;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum ValueExpression {
    Literal(serde_json::Value),
    SessionVariable(open_dds::session_variables::SessionVariable),
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum ValueExpressionOrPredicate {
    Literal(serde_json::Value),
    SessionVariable(open_dds::session_variables::SessionVariable),
    BooleanExpression(Box<model_permissions::ModelPredicate>),
}
