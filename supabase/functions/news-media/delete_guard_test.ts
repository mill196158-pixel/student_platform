import { retainNewsMedia } from './delete_guard.ts';

Deno.test('orphan retained even if a reference appears concurrently', async () => {
  const references = new Set<string>();
  const path = 'news/test/image.jpg';
  const request = Promise.resolve().then(() => retainNewsMedia(path));
  references.add(path); // The dangerous check-to-remove interleaving.
  const result = await request;
  if (!references.has(path) || result.ok !== false || result.retained !== true || result.path !== path)
    throw new Error('must report retention, never deletion');
});
