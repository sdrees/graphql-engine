use std::collections::BTreeMap;

use ndc_models;

use crate::arguments::argument_string;

pub(crate) fn definition() -> ndc_models::ObjectType {
    ndc_models::ObjectType {
        description: Some("A staff member".into()),
        fields: BTreeMap::from_iter([
            (
                "first_name".into(),
                ndc_models::ObjectField {
                    description: Some("The staff member's first name".into()),
                    r#type: ndc_models::Type::Named {
                        name: "String".into(),
                    },
                    arguments: argument_string(),
                },
            ),
            (
                "last_name".into(),
                ndc_models::ObjectField {
                    description: Some("The staff member's last name".into()),
                    r#type: ndc_models::Type::Named {
                        name: "String".into(),
                    },
                    arguments: argument_string(),
                },
            ),
            (
                "specialities".into(),
                ndc_models::ObjectField {
                    description: Some("The staff member's specialities".into()),
                    r#type: ndc_models::Type::Array {
                        element_type: Box::new(ndc_models::Type::Named {
                            name: "String".into(),
                        }),
                    },
                    arguments: BTreeMap::new(),
                },
            ),
        ]),
    }
}
