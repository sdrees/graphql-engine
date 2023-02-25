import type { SetOpenTelemetryQuery } from '../../../hasura-metadata-types';

import { useMetadataVersion, useMetadataMigration } from '../../../MetadataAPI';

import { useFireNotification } from '../../../../new-components/Notifications';
import { useInvalidateMetadata } from '../../../hasura-metadata-api';

import type { FormValues } from '../../OpenTelemetry/components/Form/schema';

import { formValuesToOpenTelemetry } from '../utils/openTelemetryToFormValues';
import { useOnSetOpenTelemetryError } from './useOnSetOpenTelemetryError';

type QueryArgs = SetOpenTelemetryQuery['args'];

function errorTransform(error: unknown) {
  return error;
}

/**
 * Allow updating the OpenTelemetry configuration.
 */
export function useSetOpenTelemetry() {
  const mutation = useMetadataMigration({ errorTransform });
  const { data: version } = useMetadataVersion();
  const invalidateMetadata = useInvalidateMetadata();

  const { fireNotification } = useFireNotification();

  const onSetOpenTelemetryError = useOnSetOpenTelemetryError(fireNotification);

  const setOpenTelemetry = (formValues: FormValues) => {
    const args: QueryArgs = formValuesToOpenTelemetry(formValues);

    // Please note: not checking if the component is still mounted or not is made on purpose because
    // the callbacks do not direct mutate any component state.
    return new Promise<void>(resolve => {
      mutation.mutate(
        {
          query: {
            type: 'set_opentelemetry_config',
            args,
            resource_version: version,
          },
        },
        {
          onSuccess: () => {
            resolve();
            invalidateMetadata();

            fireNotification({
              title: 'Success!',
              message: 'Successfully updated the OpenTelemetry Configuration',
              type: 'success',
            });
          },

          onError: err => {
            // The promise is used by Rect hook form to stop show the loading spinner but React hook
            // form must not handle errors.
            resolve();

            onSetOpenTelemetryError(err);
          },
        }
      );
    });
  };

  return {
    setOpenTelemetry,
  };
}
