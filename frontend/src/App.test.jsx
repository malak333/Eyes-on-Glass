import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import App from './App';

describe('App component', () => {
  beforeEach(() => {
    globalThis.fetch = vi.fn();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('renders without crashing', async () => {
    globalThis.fetch.mockResolvedValue({
      json: () => Promise.resolve({ logs: [] })
    });
    const { container } = render(<App />);
    expect(container).toBeTruthy();
  });

  it('sorts Old Analysis sessions from newest to oldest by completion time', async () => {
    const mockLogs = {
      logs: [
        // File A and File B have timestamps
        { id: 1, filename: 'fileA.ts', created_at: '2026-04-09T01:00:00Z', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' },
        { id: 2, filename: 'fileA.ts', created_at: '2026-04-09T01:10:00Z', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' }, // fileA max time: 01:10
        { id: 3, filename: 'fileB.ts', created_at: '2026-04-09T01:05:00Z', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' }, // fileB max time: 01:05
        
        // File D and File E do NOT have created_at (representing old logs)
        { id: 4, filename: 'fileD.ts', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' }, 
        { id: 5, filename: 'fileE.ts', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' },  // Newer than fileD based on ID

        // File C is the active stream (latest log)
        { id: 6, filename: 'fileC.ts', created_at: '2026-04-09T01:20:00Z', issue_type: 'ok', node_source: 'n1', node_backbone: 'n2', node_dest: 'n3' } 
      ]
    };
    
    globalThis.fetch.mockImplementation((url) => {
      if (url.includes('/logs')) {
        return Promise.resolve({ json: () => Promise.resolve(mockLogs) });
      }
      return Promise.resolve({ json: () => Promise.resolve({}) });
    });

    render(<App />);

    const oldAnalysisTab = await waitFor(() => screen.getByText('Old Analysis'));
    fireEvent.click(oldAnalysisTab);

    await waitFor(() => {
        expect(screen.getByText('📄 fileA.ts')).toBeTruthy();
        expect(screen.getByText('📄 fileB.ts')).toBeTruthy();
        expect(screen.getByText('📄 fileD.ts')).toBeTruthy();
        expect(screen.getByText('📄 fileE.ts')).toBeTruthy();
    });

    const items = screen.getAllByRole('listitem');
    expect(items.length).toBe(4);
    
    // Order should be:
    // 1. fileA.ts (has timestamp 01:10)
    // 2. fileB.ts (has timestamp 01:05)
    // 3. fileE.ts (no timestamp, fallback to max ID = 5)
    // 4. fileD.ts (no timestamp, fallback to max ID = 4)
    expect(items[0].textContent).toContain('fileA.ts');
    expect(items[1].textContent).toContain('fileB.ts');
    expect(items[2].textContent).toContain('fileE.ts');
    expect(items[3].textContent).toContain('fileD.ts');
  });
});
