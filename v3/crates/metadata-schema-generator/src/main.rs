use open_dds::traits::gen_root_schema_for;
use open_dds::Metadata;
use schemars::gen::SchemaGenerator;

fn main() {
    let schema = gen_root_schema_for::<Metadata>(&mut SchemaGenerator::default());
    println!("{}", serde_json::to_string_pretty(&schema).unwrap());
}
