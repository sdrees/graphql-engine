import React from 'react';
import { Story, Meta } from '@storybook/react';
import { ReactQueryDecorator } from '../../../../storybook/decorators/react-query';
import { handlers } from '../../../../mocks/metadata.mock';
import { within, userEvent } from '@storybook/testing-library';
import { waitFor } from '@testing-library/react';
import { expect } from '@storybook/jest';
import { OASGenerator, OASGeneratorProps } from './OASGenerator';
import petstore from './petstore.json';

export default {
  title: 'Features/Actions/OASGenerator',
  component: OASGenerator,
  decorators: [ReactQueryDecorator()],
  parameters: {
    msw: handlers({ delay: 500 }),
  },
  argTypes: {
    onGenerate: { action: 'Create Action' },
    onDelete: { action: 'Create Action' },
    disabled: false,
  },
} as unknown as Meta;

export const Default: Story<OASGeneratorProps> = args => {
  return <OASGenerator {...args} />;
};

Default.play = async ({ canvasElement }) => {
  const canvas = within(canvasElement);

  const input = canvas.getByTestId('file');
  userEvent.upload(
    input,
    new File([JSON.stringify(petstore)], 'test.json', {
      type: 'application/json',
    })
  );

  // wait for two seconds
  await new Promise(resolve => setTimeout(resolve, 2000));

  // wait for searchbox to appear
  const searchBox = await canvas.findByTestId('search');

  // count number of operations
  expect(canvas.getAllByTestId(/^operation.*/)).toHaveLength(4);

  // search operations with 'get'
  userEvent.type(searchBox, 'GET');
  // count filtered number of operations
  expect(canvas.getAllByTestId(/^operation.*/)).toHaveLength(2);
  // clear search
  userEvent.clear(searchBox);
  // search not existing operation
  userEvent.type(searchBox, 'not-existing');
  // look for 'No endpoints found' message
  expect(canvas.queryAllByTestId(/^operation.*/)).toHaveLength(0);
  // clear search
  userEvent.clear(searchBox);
};
