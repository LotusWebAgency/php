<?php
// Quiet set-up of the plugins that are not the shop (wp eval-file seed-plugins.php <slug>...),
// run right after they are activated. Each one ships defaults that would change what the
// suites already assert about WordPress itself, so they are configured, not worked around:
//
//  - Classic Editor replaces the block editor for everyone by default. The suites open the
//    block editor, so it stays the default and users merely may switch; the plugin is checked
//    through the classic editor screen it adds.
//  - Yoast SEO's XML sitemaps switch core's wp-sitemap.xml off and redirect it. They are off;
//    Yoast is checked through the head it prints and its admin screens.
//  - WPForms sends the first admin request to its welcome screen (2.0: its setup wizard).
//  - Wordfence's "prevent discovery of usernames" (on by default) takes anonymous /wp/v2/users, the
//    users sitemap and the oEmbed author fields away, and changes the REST bytes the golden values hash.
//    Off here, and so is its "disable application passwords" (default on from 9.0), which the REST suite uses;
//    the rest of Wordfence (firewall, login security, scanner) stays at its defaults.
require __DIR__ . '/lib.php';

$slugs = $args;
$has = function (string $slug) use ($slugs): bool {
    return in_array($slug, $slugs, true);
};
require_once ABSPATH . 'wp-admin/includes/plugin.php';

foreach ($slugs as $slug) {
    $active = false;
    foreach (get_option('active_plugins') as $file) {
        $active = $active || strpos($file, $slug . '/') === 0;
    }
    if (!$active) {
        fwrite(STDERR, "FATAL: {$slug} is not active after wp plugin activate\n");
        exit(1);
    }
}

if ($has('classic-editor')) {
    update_option('classic-editor-replace', 'block');
    update_option('classic-editor-allow-users', 'allow');
}

if ($has('wordpress-seo')) {
    if (class_exists('WPSEO_Options') && method_exists('WPSEO_Options', 'set')) {
        WPSEO_Options::set('enable_xml_sitemap', false);
    } else {
        $options = get_option('wpseo');
        $options['enable_xml_sitemap'] = false;
        update_option('wpseo', $options);
    }
}

if ($has('wordfence') && class_exists('wfConfig')) {
    wfConfig::set('loginSec_disableAuthorScan', 0);
    wfConfig::set('loginSec_disableApplicationPasswords', 0);
}

if ($has('wpforms-lite')) {
    delete_transient('wpforms_activation_redirect');
    delete_option('wpforms_activation_redirect');
    // 2.0 launches a setup wizard on the first admin request within an hour of activation, whenever that is
    // after the fixture was built; its kill switch also silences the welcome redirect.
    update_option('wpforms_setup_wizard_disabled', true);
}

// Contact Form 7 makes a sample form on activation; a page carries its shortcode so the suites can
// render and submit it. (A published page: the manifest counts are taken after this.)
$pages = [];
if ($has('contact-form-7')) {
    $forms = get_posts(['post_type' => 'wpcf7_contact_form', 'numberposts' => 1, 'orderby' => 'ID', 'order' => 'ASC', 'post_status' => 'any']);
    if (!$forms && class_exists('WPCF7_ContactForm')) {
        $form = WPCF7_ContactForm::get_template(['title' => 'Contact form 1']);
        $form->save();
        $forms = get_posts(['post_type' => 'wpcf7_contact_form', 'numberposts' => 1, 'post_status' => 'any']);
    }
    if (!$forms) {
        fwrite(STDERR, "FATAL: Contact Form 7 has no form after activation\n");
        exit(1);
    }
    wp_set_current_user(get_user_by('login', 'admin')->ID);
    $pid = wp_insert_post([
        'post_type' => 'page',
        'post_status' => 'publish',
        'post_title' => 'Contact us',
        'post_name' => 'contact-us',
        'post_content' => '[contact-form-7 id="' . $forms[0]->ID . '"]',
        'post_author' => get_user_by('login', 'admin')->ID,
    ], true);
    if (is_wp_error($pid)) {
        fwrite(STDERR, 'FATAL: contact page: ' . $pid->get_error_message() . "\n");
        exit(1);
    }
    $pages['contact_form'] = ['form_id' => $forms[0]->ID, 'page_id' => $pid, 'path' => apptest_path(get_permalink($pid))];
}
apptest_write_json(apptest_part_path('plugins'), $pages);

fwrite(STDERR, 'plugins configured: ' . implode(' ', $slugs) . "\n");
