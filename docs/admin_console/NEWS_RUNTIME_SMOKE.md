# Stage 12.2 — News runtime smoke plan

End-to-end manual check for the admin news pipeline, from draft to the mobile
student feed. Run after applying the migration and deploying the Edge Function.

## Prerequisites

- Migration `20260722070209_news_posts_and_admin_rpc.sql` applied.
- Edge Function `news-media` deployed (`createUpload`, `createDownload`,
  `delete`).
- Admin user with `content.write` (+ `content.publish` to publish).
- A student account whose active group can see `audience_type = 'all'` posts.

## Steps

1. **Draft** — In Admin Web open **Контент → Новости**. Create a draft, set a
   title/subtitle/body, pick an image variant, and upload an image. Save the
   draft (`Сохранить черновик`). Confirm the status badge shows `Черновик`.

2. **Refresh** — Reload the browser tab. The draft (with its image) must come
   back from `admin_list_news` / signed download — i.e. it survives a refresh
   and is not just local state.

3. **Publish** — Click `Опубликовать`. The badge switches to `Опубликован`.
   (A `content.write`-only account must NOT see a working publish action.)

4. **Mobile** — Open the mobile app as the student and pull-to-refresh the
   Home screen. The published card appears in the news rail. Cached feed paints
   first; the fresh `get_my_published_news` result then replaces it.

5. **Story** — Tap the card. The full-story sheet opens (`StudentNewsStorySheet`)
   showing the large hero, body text, and date. `mark_news_seen` is called on
   open; closing with `Отлично` calls it again with `closed = true`.

6. **Unpublish** — Back in Admin Web, click `Снять с публикации`. Re-refresh
   the mobile Home; the card disappears from the student feed (empty feed stays
   empty — the demo fallback is only used on RPC error with no cache).

## Extra checks

- **Versions** — `История версий` lists prior snapshots; `Восстановить` brings
  back an earlier version and bumps `version_number`.
- **Reorder** — Move a card up/down; order persists across refresh via
  `admin_reorder_news`.
- **Offline** — Kill the network on mobile and reopen Home: the last cached
  feed still shows (cache is never cleared on error).
- **Security** — Run `supabase/checks/news_posts_security_review.sql`; all
  offending-row queries return empty and the bucket is private.
