import { hasuraToast } from '../../new-components/Toasts';
import { useState } from 'react';
import { useInsertRow, FormData } from '../Data/hooks/useInsertRow';
import { useListAllTableColumns } from '../Data/hooks/useListAllTableColumns';
import { getPlaceholder } from './utils/getPlaceholder';
import { Table } from '../hasura-metadata-types/source/table';
import { InsertRowForm, InsertRowFormProps } from './InsertRowForm';

type InsertRowFormContainerProps = {
  dataSourceName: string;
  table: Table;
};

export const InsertRowFormContainer = ({
  dataSourceName,
  table,
}: InsertRowFormContainerProps) => {
  const { columns, isLoading } = useListAllTableColumns(dataSourceName, table);

  const onInsertSuccess = () =>
    hasuraToast({
      type: 'success',
      title: 'Success',
      message: 'The row has been successfully inserted',
    });

  const onInsertError = (error: Error) => {
    hasuraToast({
      type: 'error',
      title: 'Error while inserting row',
      message: error.message,
    });
  };

  const { insertRow } = useInsertRow({
    dataSourceName,
    table,
    onSuccess: onInsertSuccess,
    onError: onInsertError,
  });

  const [isInserting, setInserting] = useState(false);

  const onInsertRow = async (formData: FormData) => {
    setInserting(true);
    await insertRow(formData);
    setInserting(false);
  };

  const columnsWithPlaceholder: InsertRowFormProps['columns'] = columns.map(
    column => {
      return {
        ...column,
        placeholder: getPlaceholder(column.dataType),
      };
    }
  );

  return (
    <InsertRowForm
      columns={columnsWithPlaceholder}
      isInserting={isInserting}
      isLoading={isLoading}
      onInsertRow={onInsertRow}
    />
  );
};
