import { describe, it, expect, vi, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import useToasts from './useToasts';

afterEach(() => {
  vi.useRealTimers();
});

describe('useToasts', () => {
  it('gives toasts added in the same millisecond unique ids and expires them', () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useToasts());

    act(() => {
      result.current.addToast('first', 'success');
      result.current.addToast('second', 'error');
    });
    const ids = result.current.toasts.map((t) => t.id);
    expect(new Set(ids).size).toBe(2);

    act(() => result.current.removeToast(ids[0]));
    expect(result.current.toasts.map((t) => t.message)).toEqual(['second']);

    act(() => vi.advanceTimersByTime(4000));
    expect(result.current.toasts).toEqual([]);
  });

  it('keeps callbacks stable across renders', () => {
    const { result, rerender } = renderHook(() => useToasts());
    const { addToast, removeToast } = result.current;
    rerender();
    expect(result.current.addToast).toBe(addToast);
    expect(result.current.removeToast).toBe(removeToast);
  });
});
