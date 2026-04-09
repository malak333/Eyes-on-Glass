import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { describe, test, expect } from 'vitest';
import LogViewer from './LogViewer';

describe('LogViewer Component', () => {
  test('renders "No logs collected yet." when empty', () => {
    render(<LogViewer logs={[]} apiUrl="http://localhost:8080" />);
    expect(screen.getByText('No logs collected yet.')).toBeInTheDocument();
  });

  test('reverses the logs so that the newest ones are displayed at the top', () => {
    const logs = [
      { id: 1, issue_type: 'ok', timestamp_sec: 1.0, filename: 'test1.ts' },
      { id: 2, issue_type: 'ok', timestamp_sec: 2.0, filename: 'test1.ts' }
    ];

    const { container } = render(<LogViewer logs={logs} apiUrl="http://localhost:8080" />);
    
    // The "OK" strings are upper-cased
    const displayedTexts = Array.from(container.querySelectorAll('span')).map(node => node.textContent);
    
    // We expect the timestamp of id 2 (2.0s) to appear before id 1 (1.0s)
    const time2Index = displayedTexts.findIndex(t => t.includes('2.00s'));
    const time1Index = displayedTexts.findIndex(t => t.includes('1.00s'));
    
    expect(time2Index !== -1).toBe(true);
    expect(time1Index !== -1).toBe(true);
    expect(time2Index).toBeLessThan(time1Index);
  });

  test('filters out "ok" logs when there are issues', () => {
    const logs = [
      { id: 1, issue_type: 'ok', timestamp_sec: 1.0, filename: 'test1.ts' },
      { id: 2, issue_type: 'black_screen', timestamp_sec: 2.0, filename: 'test1.ts' },
      { id: 3, issue_type: 'ok', timestamp_sec: 3.0, filename: 'test1.ts' }
    ];

    render(<LogViewer logs={logs} apiUrl="http://localhost:8080" />);
    
    // black_screen should be present
    expect(screen.getByText('BLACK SCREEN')).toBeInTheDocument();
    
    // "ok" logs should NOT be present if there are issues
    const okElements = screen.queryAllByText('OK');
    expect(okElements.length).toBe(0);
  });
});
