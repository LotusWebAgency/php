<?php

// Builds the content model and the content for the corpus Drupal, through its
// own entity API so every row passes the hooks, path aliases and search-index
// bookkeeping a real editor's save would. Run by `drush php:script` from
// Dockerfile.corpus after site:install, with comment, search and search_node
// enabled and before cron builds the search index.
//
// The Standard profile of 11.4 ships no content types at all (no article, page,
// body field or comment type), so they are created here.
// Result: 20 promoted, tagged articles with three comments each (nodes 1-20) and
// 2 basic pages (nodes 21-22). corpus/drupal/endpoints names these ids and the
// strings below; keep them in step.

use Drupal\comment\Entity\Comment;
use Drupal\field\Entity\FieldConfig;
use Drupal\field\Entity\FieldStorageConfig;
use Drupal\node\Entity\Node;
use Drupal\node\Entity\NodeType;
use Drupal\taxonomy\Entity\Term;
use Drupal\user\RoleInterface;

$displays = \Drupal::service('entity_display.repository');

foreach (['article' => 'Article', 'page' => 'Basic page'] as $id => $name) {
  NodeType::create(['type' => $id, 'name' => $name, 'new_revision' => TRUE])->save();
}

FieldStorageConfig::create([
  'field_name' => 'body',
  'entity_type' => 'node',
  'type' => 'text_with_summary',
])->save();
FieldStorageConfig::create([
  'field_name' => 'field_tags',
  'entity_type' => 'node',
  'type' => 'entity_reference',
  'cardinality' => FieldStorageConfig::CARDINALITY_UNLIMITED,
  'settings' => ['target_type' => 'taxonomy_term'],
])->save();

foreach (['article', 'page'] as $bundle) {
  FieldConfig::create([
    'field_name' => 'body',
    'entity_type' => 'node',
    'bundle' => $bundle,
    'label' => 'Body',
    'settings' => ['display_summary' => TRUE],
  ])->save();
  $displays->getFormDisplay('node', $bundle)
    ->setComponent('body', ['type' => 'text_textarea_with_summary'])
    ->save();
  $displays->getViewDisplay('node', $bundle)
    ->setComponent('body', ['label' => 'hidden', 'type' => 'text_default'])
    ->save();
  // The front page view renders teasers.
  $displays->getViewDisplay('node', $bundle, 'teaser')
    ->setStatus(TRUE)
    ->setComponent('body', ['label' => 'hidden', 'type' => 'text_summary_or_trimmed'])
    ->save();
}

FieldConfig::create([
  'field_name' => 'field_tags',
  'entity_type' => 'node',
  'bundle' => 'article',
  'label' => 'Tags',
  'settings' => [
    'handler' => 'default',
    'handler_settings' => ['target_bundles' => ['tags' => 'tags'], 'auto_create' => TRUE],
  ],
])->save();
$displays->getFormDisplay('node', 'article')
  ->setComponent('field_tags', ['type' => 'entity_reference_autocomplete_tags'])
  ->save();
foreach (['default', 'teaser'] as $mode) {
  $displays->getViewDisplay('node', 'article', $mode)
    ->setComponent('field_tags', ['type' => 'entity_reference_label', 'weight' => 10])
    ->save();
}

// Comments on articles, the way CommentTestTrait::addDefaultCommentField lays
// them out: a comment type with a body, a comment field on the bundle, and the
// field shown (not teasered) in the full view mode.
\Drupal::entityTypeManager()->getStorage('comment_type')->create([
  'id' => 'comment',
  'label' => 'Comment',
  'target_entity_type_id' => 'node',
])->save();
\Drupal::service('comment.manager')->addBodyField('comment');
FieldStorageConfig::create([
  'field_name' => 'comment',
  'entity_type' => 'node',
  'type' => 'comment',
  'translatable' => TRUE,
  'settings' => ['comment_type' => 'comment'],
])->save();
FieldConfig::create([
  'field_name' => 'comment',
  'entity_type' => 'node',
  'bundle' => 'article',
  'label' => 'Comments',
  'default_value' => [['status' => 2, 'cid' => 0, 'last_comment_name' => '', 'last_comment_timestamp' => 0, 'last_comment_uid' => 0]],
])->save();
$displays->getFormDisplay('node', 'article')
  ->setComponent('comment', ['type' => 'comment_default', 'weight' => 20])
  ->save();
$displays->getViewDisplay('node', 'article')
  ->setComponent('comment', ['label' => 'above', 'type' => 'comment_default', 'weight' => 20, 'settings' => ['view_mode' => 'full']])
  ->save();

// Visitors are anonymous. Comments and the search form are denied to them
// unless the role carries these.
user_role_grant_permissions(RoleInterface::ANONYMOUS_ID, ['access comments', 'search content']);

$terms = [];
for ($i = 1; $i <= 5; $i++) {
  $term = Term::create(['vid' => 'tags', 'name' => 'corpus-tag-' . $i]);
  $term->save();
  $terms[] = $term->id();
}

$lorem = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor '
  . 'incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud '
  . 'exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. ';

for ($i = 1; $i <= 20; $i++) {
  $node = Node::create([
    'type' => 'article',
    'title' => 'Corpus article ' . $i,
    'uid' => 1,
    'status' => 1,
    'promote' => 1,
    'created' => 1700000000 + $i * 3600,
    'body' => [
      'value' => '<p>' . str_repeat($lorem, 4) . '</p><p>Training corpus entry number ' . $i . '. ' . str_repeat($lorem, 2) . '</p>',
      'format' => 'basic_html',
    ],
    'field_tags' => [
      ['target_id' => $terms[$i % 5]],
      ['target_id' => $terms[($i + 1) % 5]],
    ],
    'comment' => [['status' => 2]],
  ]);
  $node->save();

  for ($c = 0; $c < 3; $c++) {
    Comment::create([
      'entity_type' => 'node',
      'entity_id' => $node->id(),
      'field_name' => 'comment',
      'comment_type' => 'comment',
      'uid' => 0,
      'name' => 'commenter' . $c,
      'status' => 1,
      'subject' => 'Comment ' . $c . ' on article ' . $i,
      'comment_body' => [
        'value' => 'Comment body ' . $c . '. ' . $lorem,
        'format' => 'plain_text',
      ],
    ])->save();
  }
}

foreach (['Corpus handbook', 'Corpus colophon'] as $title) {
  Node::create([
    'type' => 'page',
    'title' => $title,
    'uid' => 1,
    'status' => 1,
    'promote' => 0,
    'body' => [
      'value' => '<p>' . str_repeat($lorem, 6) . '</p>',
      'format' => 'basic_html',
    ],
  ])->save();
}

echo 'seeded ' . \Drupal::database()->query('SELECT COUNT(*) FROM {node_field_data}')->fetchField() . " nodes\n";
