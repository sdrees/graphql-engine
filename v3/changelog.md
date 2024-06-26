# Changelog

## [Unreleased]

### Added

#### Aggregates of Array Relationships

Aggregates of array relationships can now be defined by specifying an
`aggregate` in the `Relationship`'s target. Note that this is only supported
when the target of the relationship is a `Model`. You must also specify the
`aggregateFieldName` under the `graphql` section.

```yaml
kind: Relationship
version: v1
definition:
  name: invoices
  sourceType: Customer
  target:
    model:
      name: Invoice
      relationshipType: Array
      aggregate: # New!
        aggregateExpression: Invoice_aggregate_exp
        description: Aggregate of the customer's invoices
  mapping:
    - source:
        fieldPath:
          - fieldName: customerId
      target:
        modelField:
          - fieldName: customerId
  graphql: # New!
    aggregateFieldName: invoicesAggregate
```

### Changed

### Fixed

## [v2024.06.13]

Initial release.

<!-- end -->

[Unreleased]: https://github.com/hasura/v3-engine/compare/v2024.06.13...HEAD
[v2024.06.13]: https://github.com/hasura/v3-engine/releases/tag/v2024.06.13
