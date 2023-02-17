import inflection from 'inflection';
import { isEqual } from '@/components/Common/utils/jsUtils';
import {
  LocalRelationship,
  SuggestedRelationship,
} from '@/features/DatabaseRelationships/types';
import { getTableDisplayName } from '@/features/DatabaseRelationships/utils/helpers';
import { getDriverPrefix, runMetadataQuery } from '@/features/DataSource';
import {
  areTablesEqual,
  MetadataSelectors,
} from '@/features/hasura-metadata-api';
import { useMetadata } from '@/features/hasura-metadata-api/useMetadata';
import { Table } from '@/features/hasura-metadata-types';
import { useHttpClient } from '@/features/Network';
import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from 'react-query';
import { generateQueryKeys } from '@/features/DatabaseRelationships/utils/queryClientUtils';
import { useMetadataMigration } from '@/features/MetadataAPI';

type UseSuggestedRelationshipsArgs = {
  dataSourceName: string;
  table: Table;
  existingRelationships: LocalRelationship[];
  isEnabled: boolean;
};

export type SuggestedRelationshipsResponse = {
  relationships: SuggestedRelationship[];
};

type FilterTableRelationshipsArgs = {
  table: Table;
  relationships: SuggestedRelationship[];
};

export const filterTableRelationships = ({
  table,
  relationships,
}: FilterTableRelationshipsArgs) =>
  relationships.filter(relationship => {
    if (areTablesEqual(relationship.from.table, relationship.to.table)) {
      return false;
    }
    return areTablesEqual(relationship.from.table, table);
  });

export type SuggestedRelationshipWithName = SuggestedRelationship & {
  constraintName: string;
};

type GetRelationTableNameArg = {
  table: Table;
  relationshipType: SuggestedRelationship['type'];
};

const formatRelationToTableName = ({
  table,
  relationshipType,
}: GetRelationTableNameArg) => {
  const baseTableName = getTableDisplayName(table);
  if (relationshipType === 'array') {
    return inflection.pluralize(baseTableName);
  }

  return inflection.singularize(getTableDisplayName(table));
};

const makeStringGraphQLCompliant = (text: string) => text.replace(/\./g, '_');

export const addConstraintName = (
  relationships: SuggestedRelationship[]
): SuggestedRelationshipWithName[] =>
  relationships.map(relationship => {
    const fromTable = getTableDisplayName(relationship.from.table);
    const fromColumns = relationship.from.columns.join('_');
    const toTableName = formatRelationToTableName({
      table: relationship.to.table,
      relationshipType: relationship.type,
    });
    const toColumns = relationship.to.columns.join('_');
    const toTableWithColumns = `${toTableName}_${toColumns}`;
    const constraintName = makeStringGraphQLCompliant(
      `${fromTable}_${fromColumns}_${toTableWithColumns}`
    );

    return {
      ...relationship,
      constraintName,
    };
  });

type RemoveExistingRelationshipsArgs = {
  relationships: SuggestedRelationship[];
  existingRelationships: LocalRelationship[];
};

export const removeExistingRelationships = ({
  relationships,
  existingRelationships,
}: RemoveExistingRelationshipsArgs) =>
  relationships.filter(relationship => {
    const fromTable = relationship.from.table;

    const fromTableExists = existingRelationships.find(rel =>
      areTablesEqual(rel.fromTable, fromTable)
    );

    if (!fromTableExists) {
      return true;
    }

    const existingRelationshipsFromSameTable = existingRelationships.filter(
      rel => areTablesEqual(rel.fromTable, fromTable)
    );

    const toTable = relationship.to.table;
    const toTableExists = existingRelationshipsFromSameTable.find(rel =>
      areTablesEqual(rel.definition.toTable, toTable)
    );

    if (!toTableExists) {
      return true;
    }

    const existingRelationshipsFromAndToSameTable =
      existingRelationshipsFromSameTable.filter(rel =>
        areTablesEqual(rel.definition.toTable, toTable)
      );

    const existingRelationshipsFromAndToSameTableAndSameFromColumns =
      existingRelationshipsFromAndToSameTable.filter(rel => {
        const existingToColumns = Object.values(rel.definition.mapping).sort();
        const relationshipToColumns = relationship.to.columns.sort();

        return isEqual(existingToColumns, relationshipToColumns);
      });

    if (!existingRelationshipsFromAndToSameTableAndSameFromColumns) {
      return true;
    }

    return false;
  });

export const useSuggestedRelationships = ({
  dataSourceName,
  table,
  existingRelationships,
  isEnabled,
}: UseSuggestedRelationshipsArgs) => {
  const { data: metadataSource } = useMetadata(
    MetadataSelectors.findSource(dataSourceName)
  );

  const metadataMutation = useMetadataMigration({});

  const queryClient = useQueryClient();

  const dataSourcePrefix = metadataSource?.kind
    ? getDriverPrefix(metadataSource?.kind)
    : undefined;

  const httpClient = useHttpClient();

  const {
    data,
    refetch: refetchSuggestedRelationships,
    isLoading: isLoadingSuggestedRelationships,
  } = useQuery({
    queryKey: ['suggested_relationships', dataSourceName, table],
    queryFn: async () => {
      const body = {
        type: `${dataSourcePrefix}_suggest_relationships`,
        args: {
          omit_tracked: true,
          tables: [table],
          source: dataSourceName,
        },
      };
      const result = await runMetadataQuery<SuggestedRelationshipsResponse>({
        httpClient,
        body,
      });

      return result;
    },
    enabled: isEnabled,
  });

  const [isAddingSuggestedRelationship, setAddingSuggestedRelationship] =
    useState(false);

  const onAddSuggestedRelationship = async ({
    name,
    columnNames,
    relationshipType,
    toTable,
  }: {
    name: string;
    columnNames: string[];
    relationshipType: 'object' | 'array';
    toTable?: Table;
  }) => {
    setAddingSuggestedRelationship(true);

    await metadataMutation.mutateAsync({
      query: {
        type: `${dataSourcePrefix}_create_${relationshipType}_relationship`,
        args: {
          table,
          name,
          source: dataSourceName,
          using: {
            foreign_key_constraint_on:
              relationshipType === 'object'
                ? columnNames
                : {
                    table: toTable,
                    columns: columnNames,
                  },
          },
        },
      },
    });
    setAddingSuggestedRelationship(false);

    queryClient.invalidateQueries({
      queryKey: generateQueryKeys.metadata(),
    });
  };

  useEffect(() => {
    if (dataSourcePrefix) {
      refetchSuggestedRelationships();
    }
  }, [dataSourcePrefix]);

  const suggestedRelationships = data?.relationships || [];

  const tableFilteredRelationships = filterTableRelationships({
    table,
    relationships: suggestedRelationships,
  });

  // TODO: remove when the metadata request will correctly omit already tracked relationships
  const notExistingRelationships = removeExistingRelationships({
    relationships: tableFilteredRelationships,
    existingRelationships,
  });

  const relationshipsWithConstraintName = addConstraintName(
    notExistingRelationships
  );

  return {
    suggestedRelationships: relationshipsWithConstraintName,
    isLoadingSuggestedRelationships,
    refetchSuggestedRelationships,
    onAddSuggestedRelationship,
    isAddingSuggestedRelationship,
  };
};
