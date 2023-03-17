import React from 'react';
import AceEditor from 'react-ace';
import { useFormContext } from 'react-hook-form';
import { MetadataTable, Table } from '../../../hasura-metadata-types';
import { useHttpClient } from '../../../Network';
import { useQuery } from 'react-query';
import { DataSource, exportMetadata, Operator } from '../../../DataSource';
import { areTablesEqual } from '../../../hasura-metadata-api';
import { getTypeName } from '../../../GraphQLUtils';
import { InputField } from '../../../../new-components/Form';
import { IconTooltip } from '../../../../new-components/Tooltip';
import { Collapse } from '../../../../new-components/deprecated';
import { getIngForm } from '../../../../components/Services/Data/utils';
import { RowPermissionBuilder } from './RowPermissionsBuilder';
import { QueryType } from '../../types';
import { ReturnValue } from '../hooks';
import { useMetadataTable } from '../../../hasura-metadata-api/metadataHooks';
import { getNonSelectedQueryTypePermissions } from '../utils/getMapQueryTypePermissions';

const NoChecksLabel = () => (
  <span data-test="without-checks">Without any checks&nbsp;</span>
);

const CustomLabel = () => (
  <span data-test="custom-check" className="flex items-center">
    With custom check:
    <IconTooltip message="Create custom check using permissions builder" />
  </span>
);

export interface RowPermissionsProps {
  table: unknown;
  queryType: QueryType;
  subQueryType?: string;
  dataSourceName: string;
  supportedOperators: Operator[];
  defaultValues: ReturnValue['defaultValues'];
  permissionsKey: 'check' | 'filter';
  roleName: string;
}

enum SelectedSection {
  NoChecks = 'no_checks',
  Custom = 'custom',
  NoneSelected = 'none',
  insert = 'insert',
  select = 'select',
  update = 'update',
  delete = 'delete',
}

const getRowPermission = (queryType: QueryType, subQueryType?: string) => {
  if (queryType === 'insert') {
    return 'check';
  }

  if (queryType === 'update') {
    if (subQueryType === 'post') {
      return 'check';
    }

    return 'filter';
  }

  return 'filter';
};

const getRowPermissionCheckType = (
  queryType: QueryType,
  subQueryType?: string
) => {
  if (queryType === 'insert') {
    return 'checkType';
  }

  if (queryType === 'update') {
    if (subQueryType === 'post') {
      return 'checkType';
    }

    return 'filterType';
  }

  return 'filterType';
};

const useTypeName = ({
  table,
  dataSourceName,
}: {
  table: Table;
  dataSourceName: string;
}) => {
  const httpClient = useHttpClient();

  return useQuery({
    queryKey: ['gql_introspection', 'type_name', table, dataSourceName],
    queryFn: async () => {
      const { metadata } = await exportMetadata({ httpClient });
      const metadataSource = metadata.sources.find(
        s => s.name === dataSourceName
      );
      const metadataTable = metadataSource?.tables.find(t =>
        areTablesEqual(t.table, table)
      );

      if (!metadataSource || !metadataTable)
        throw Error('unable to generate type name');

      const defaultQueryRoot = await DataSource(httpClient).getDefaultQueryRoot(
        {
          dataSourceName,
          table,
        }
      );

      // This is very GDC specific. We have to move this to DAL later
      const typeName = getTypeName({
        defaultQueryRoot,
        operation: 'select',
        sourceCustomization: metadataSource?.customization,
        configuration: metadataTable.configuration,
      });

      return typeName;
    },
  });
};

const getUpdatePermissionBuilderIdSuffix = (
  id: string,
  subQueryType: string | undefined
) => {
  if (subQueryType) return `${id}-${subQueryType}`;
  return id;
};

export const RowPermissionsSection: React.FC<RowPermissionsProps> = ({
  table,
  queryType,
  subQueryType,
  dataSourceName,
  defaultValues,
  permissionsKey,
  roleName,
}) => {
  const { data: tableName, isLoading } = useTypeName({ table, dataSourceName });
  const metadataTable = useMetadataTable(dataSourceName, table);

  const nonSelectedQueryTypePermissions = getNonSelectedQueryTypePermissions(
    metadataTable?.data as MetadataTable,
    queryType,
    roleName
  );

  const { watch, setValue, reset, getValues } = useFormContext();
  // determines whether the inputs should be pointed at `check` or `filter`
  const rowPermissions = getRowPermission(queryType, subQueryType);
  // determines whether the check type should be pointer at `checkType` or `filterType`
  const rowPermissionsCheckType = getRowPermissionCheckType(
    queryType,
    subQueryType
  );

  const selectedSection = watch(rowPermissionsCheckType);
  return (
    <fieldset key={queryType} className="grid gap-2">
      <div>
        <label className="flex items-center gap-2">
          <input
            id={SelectedSection.NoChecks}
            type="radio"
            value={SelectedSection.NoChecks}
            checked={selectedSection === SelectedSection.NoChecks}
            onClick={() => {
              setValue(rowPermissionsCheckType, SelectedSection.NoChecks);
              setValue(rowPermissions, {});
            }}
          />
          <NoChecksLabel />
        </label>

        {selectedSection === SelectedSection.NoChecks && (
          <div className="mt-4 p-6 rounded-lg bg-white border border-gray-200 min-h-32 w-full">
            <AceEditor
              mode="json"
              minLines={1}
              fontSize={14}
              height="18px"
              width="100%"
              theme="github"
              name={`${tableName}-json-editor`}
              value="{}"
              onChange={() =>
                setValue(rowPermissionsCheckType, SelectedSection.Custom)
              }
              editorProps={{ $blockScrolling: true }}
              setOptions={{ useWorker: false }}
            />
          </div>
        )}
      </div>

      {nonSelectedQueryTypePermissions &&
        nonSelectedQueryTypePermissions?.map(
          ({ queryType: type, data }: Record<string, any>) => (
            <div key={`${type}${queryType}`}>
              <label className="flex items-center gap-2">
                <input
                  id={`custom_${type}`}
                  data-testid={getUpdatePermissionBuilderIdSuffix(
                    `external-${roleName}-${type}-input`,
                    subQueryType
                  )}
                  type="radio"
                  value={type}
                  checked={selectedSection === type}
                  onClick={() => {
                    reset({
                      ...getValues(),
                      ...data,
                      queryType,
                    });

                    setValue(rowPermissionsCheckType, type);
                  }}
                />
                <span data-test="mutual-check">
                  With same custom check as&nbsp;<strong>{type}</strong>
                </span>
              </label>

              {selectedSection === type && (
                <div
                  // Permissions are not otherwise stored in plan JSON format in the dom.
                  // This is a hack to get the JSON into the dom for testing.
                  data-state={JSON.stringify(data[getRowPermission(type)])}
                  data-testid="external-check-json-editor"
                  className="mt-4 p-6 rounded-lg bg-white border border-gray-200 min-h-32 w-full"
                >
                  <AceEditor
                    mode="json"
                    minLines={1}
                    fontSize={14}
                    height="18px"
                    width="100%"
                    theme="github"
                    name={`${tableName}-json-editor`}
                    value={JSON.stringify(data[getRowPermission(type)])}
                    onChange={() => setValue(rowPermissionsCheckType, type)}
                    editorProps={{ $blockScrolling: true }}
                    setOptions={{ useWorker: false }}
                  />
                </div>
              )}
            </div>
          )
        )}

      <div>
        <label className="flex items-center gap-2">
          <input
            id={SelectedSection.Custom}
            type="radio"
            data-testid={getUpdatePermissionBuilderIdSuffix(
              `custom-${roleName}-${queryType}-input`,
              subQueryType
            )}
            value={SelectedSection.Custom}
            checked={selectedSection === SelectedSection.Custom}
            onClick={() => {
              setValue(rowPermissionsCheckType, SelectedSection.Custom);
              // eslint-disable-next-line @typescript-eslint/ban-ts-comment
              // @ts-ignore
              // problem with inferring other types than select which does not have 'check'
              setValue(rowPermissions, defaultValues[rowPermissions]);
            }}
          />
          <CustomLabel />
        </label>

        {selectedSection === SelectedSection.Custom && (
          <div className="pt-4">
            {!isLoading && tableName ? (
              <RowPermissionBuilder
                permissionsKey={permissionsKey}
                table={table}
                dataSourceName={dataSourceName}
              />
            ) : (
              <>Loading...</>
            )}
          </div>
        )}
      </div>

      {queryType === 'select' && (
        <div className="w-40">
          <InputField label="Limit number of rows" name="rowCount" />
        </div>
      )}
    </fieldset>
  );
};

export interface RowPermissionsWrapperProps {
  queryType: QueryType;
  roleName: string;
  defaultOpen?: boolean;
}

const getStatus = (rowPermissions: string) => {
  if (!rowPermissions) {
    return 'No access';
  }

  if (rowPermissions === '{}') {
    return 'Without any checks';
  }

  return 'With custom checks';
};

export const RowPermissionsSectionWrapper: React.FC<
  RowPermissionsWrapperProps
> = ({ children, queryType, roleName, defaultOpen }) => {
  const { watch } = useFormContext();

  const rowPermissions = watch('rowPermissions');
  const status = React.useMemo(
    () => getStatus(rowPermissions),
    [rowPermissions]
  );

  return (
    <Collapse
      title={`Row ${queryType} permissions`}
      tooltip={`Set permission rule for ${getIngForm(queryType)} rows`}
      status={status}
      defaultOpen={defaultOpen}
      data-test="toggle-row-permission"
    >
      <Collapse.Content>
        <div className="mb-2">
          <p>
            Allow role <strong>{roleName}</strong> to {queryType}&nbsp;
            <strong>rows</strong>:
          </p>
        </div>
        {children}
      </Collapse.Content>
    </Collapse>
  );
};

export default RowPermissionsSection;
