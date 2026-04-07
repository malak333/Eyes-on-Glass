import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import MetricsCard from './components/MetricsCard';

describe('MetricsCard component', () => {
  it('renders title and value correctly', () => {
    render(<MetricsCard title="Test Metric" value="999" icon={<span>TestIcon</span>} />);
    
    expect(screen.getByText('Test Metric')).toBeTruthy();
    expect(screen.getByText('999')).toBeTruthy();
    expect(screen.getByText('TestIcon')).toBeTruthy();
  });
});
