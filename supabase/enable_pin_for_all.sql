-- Enable pin/unpin for all team members
-- 1) Ensure is_pinned column exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'messages'
      AND column_name = 'is_pinned'
  ) THEN
    ALTER TABLE public.messages
      ADD COLUMN is_pinned boolean NOT NULL DEFAULT false;
  END IF;
END $$;

-- 2) Allow all team members to update is_pinned via RLS
-- Drop old policy if exists
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polname = 'messages_update_pin' AND polrelid = 'public.messages'::regclass
  ) THEN
    DROP POLICY messages_update_pin ON public.messages;
  END IF;
END $$;

-- Create broad policy: any member of the team of this chat can update is_pinned
CREATE POLICY messages_update_pin ON public.messages
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.chats c
      JOIN public.team_members tm ON tm.team_id = c.team_id AND tm.user_id = auth.uid()
      WHERE c.id = messages.chat_id
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.chats c
      JOIN public.team_members tm ON tm.team_id = c.team_id AND tm.user_id = auth.uid()
      WHERE c.id = messages.chat_id
    )
  );

-- 3) Ensure messages table is in realtime publication
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  END IF;
END $$;

-- 4) Create RPC for pin/unpin if missing
CREATE OR REPLACE FUNCTION public.pin_message(p_message_id uuid, p_pinned boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.messages m
  SET is_pinned = p_pinned
  WHERE m.id = p_message_id;
END;
$$;








