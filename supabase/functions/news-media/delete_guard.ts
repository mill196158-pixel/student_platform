/** This rollout retains every object: a reference check and Storage delete are
 * not atomic, so even a currently unreferenced object cannot be removed safely. */
export function retainNewsMedia(path: string): { action: 'delete'; path: string; ok: false; retained: true } {
  return { action: 'delete', path, ok: false, retained: true };
}
