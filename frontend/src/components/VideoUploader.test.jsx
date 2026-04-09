import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import VideoUploader from './VideoUploader';

describe('VideoUploader component', () => {
  it('calls onStopLive when live stream is stopped', async () => {
    // Mock fetch
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        json: () => Promise.resolve({}),
      })
    );

    const mockOnStopLive = vi.fn();
    
    render(<VideoUploader onUploadSuccess={() => {}} onStopLive={mockOnStopLive} apiUrl="http://localhost:8080" />);
    
    // Start live stream first
    const startButton = screen.getByText('Start Live');
    fireEvent.click(startButton);

    // Wait for the button to change to Stop Live
    await waitFor(() => {
        expect(screen.getByText('Stop Live')).toBeTruthy();
    });

    const stopButton = screen.getByText('Stop Live');
    fireEvent.click(stopButton);

    await waitFor(() => {
        expect(mockOnStopLive).toHaveBeenCalled();
    });
  });
});
