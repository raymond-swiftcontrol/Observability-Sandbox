DROP TABLE IF EXISTS social.leaderboard_entry CASCADE;
DROP TABLE IF EXISTS social.message CASCADE;
DROP TABLE IF EXISTS social.conversation_member, social.conversation CASCADE;
DROP TRIGGER IF EXISTS trg_group_member_count ON social.group_member;
DROP FUNCTION IF EXISTS social.sync_group_member_count();
ALTER TABLE social.post DROP CONSTRAINT IF EXISTS post_group_fk;
DROP TABLE IF EXISTS social.group_member, social.group CASCADE;
DROP TYPE IF EXISTS social.conversation_state, social.group_role, social.group_visibility;
