DROP TRIGGER IF EXISTS trg_post_rationale ON social.post;
DROP FUNCTION IF EXISTS social.measure_rationale();
DROP TRIGGER IF EXISTS trg_post_relations ON social.post;
DROP FUNCTION IF EXISTS social.sync_post_relations();
DROP TRIGGER IF EXISTS trg_bookmark_counter ON social.bookmark;
DROP FUNCTION IF EXISTS social.sync_bookmark_counter();
DROP TRIGGER IF EXISTS trg_reaction_counter ON social.reaction;
DROP FUNCTION IF EXISTS social.sync_reaction_counter();
DROP FUNCTION IF EXISTS social.bump_post_counter(uuid, text, integer);
DROP TABLE IF EXISTS social.bookmark, social.reaction, social.post_attachment,
  social.post_mention, social.unresolved_cashtag, social.post_instrument,
  social.post CASCADE;
DROP TYPE IF EXISTS social.reaction_kind, social.moderation_state,
  social.verification, social.attachment_kind, social.post_kind;
