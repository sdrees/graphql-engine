import { areTablesEqual } from '../../../../../hasura-metadata-api';
import { useContext, useEffect } from 'react';
import { rowPermissionsContext } from './RowPermissionsProvider';
import { tableContext } from './TableProvider';
import { Table } from '../../../../../hasura-metadata-types';
import { getTableDisplayName } from '../../../../../DatabaseRelationships';
import { isEmpty } from 'lodash';
import { Button } from '../../../../../../new-components/Button';
import { graphQLTypeToJsType, isComparator } from './utils';
import { ValueInputType } from './ValueInputType';

export const ValueInput = ({ value, path }: { value: any; path: string[] }) => {
  const { setValue, tables, comparators } = useContext(rowPermissionsContext);
  const { table, columns, setTable, setComparator } = useContext(tableContext);
  const comparatorName = path[path.length - 1];
  const componentLevelId = `${path.join('.')}-value-input`;

  const stringifiedTable = JSON.stringify(table);
  // Sync table name with ColumnsContext table value
  useEffect(() => {
    if (comparatorName === '_table' && !areTablesEqual(value, table)) {
      setTable(value);
    }
  }, [comparatorName, stringifiedTable, value, setTable, setComparator]);

  if (comparatorName === '_table') {
    // Select table
    return (
      <div className="ml-6">
        <div className="p-2 flex gap-4">
          <select
            data-testid={componentLevelId}
            className="border border-gray-200 rounded-md"
            value={JSON.stringify(value)}
            onChange={e => {
              setValue(path, JSON.parse(e.target.value) as Table);
            }}
          >
            <option value="">-</option>
            {tables.map(t => {
              const tableDisplayName = getTableDisplayName(t.table);
              return (
                // Call JSON.stringify because value cannot be array or object. Will be parsed in setValue
                <option key={tableDisplayName} value={JSON.stringify(t.table)}>
                  {tableDisplayName}
                </option>
              );
            })}
          </select>
        </div>
      </div>
    );
  }
  const parent = path[path.length - 2];
  const column = columns.find(c => c.name === parent);
  const comparator = comparators[column?.type || '']?.operators.find(
    o => o.operator === comparatorName
  );
  const jsType = typeof graphQLTypeToJsType(value, comparator?.type);
  const inputType =
    jsType === 'boolean' ? 'checkbox' : jsType === 'string' ? 'text' : 'number';

  return (
    <>
      <ValueInputType
        jsType={jsType}
        componentLevelId={componentLevelId}
        path={path}
        comparatorName={comparatorName}
        value={value}
        comparatorType={comparator?.type}
      />
      {(inputType === 'text' || inputType === 'number') &&
        isComparator(comparatorName) && (
          <Button
            disabled={comparatorName === '_where' && isEmpty(table)}
            onClick={() => setValue(path, 'X-Hasura-User-Id')}
            data-testid={`${componentLevelId}-x-hasura-user-id`}
            mode="default"
          >
            [x-hasura-user-id]
          </Button>
        )}
    </>
  );
};
