(function () {
    'use strict';

    var PLUGIN_ID = 'com.nst.wordmark';
    var STYLE_ID = 'nst-wordmark-style';
    var BRAND_TEXT = 'NST';
    var EDITION_TEXT = 'BETA VERSION';
    var CHANNEL_BRAND_CLASS = 'nst-wordmark-text';
    var LOGIN_BRAND_CLASS = 'nst-login-wordmark-text';
    var CHANNEL_ROOT_ATTRIBUTE = 'data-nst-wordmark-root';
    var LOGIN_ROOT_ATTRIBUTE = 'data-nst-login-wordmark-root';
    var HIDDEN_SITE_ATTRIBUTE = 'data-nst-hidden-site-name';
    var ORIGINAL_ARIA_ATTRIBUTE = 'data-nst-original-aria-label';
    var ORIGINAL_EDITION_ATTRIBUTE = 'data-nst-original-edition-label';

    function installStyle() {
        if (document.getElementById(STYLE_ID)) {
            return;
        }

        var style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = [
            '#product_switch_menu [' + CHANNEL_ROOT_ATTRIBUTE + '] > svg {',
            '    display: none !important;',
            '}',
            '#product_switch_menu .' + CHANNEL_BRAND_CLASS + ' {',
            '    display: inline-flex;',
            '    height: 20px;',
            '    align-items: center;',
            '    margin: 0 !important;',
            '    color: rgba(var(--sidebar-text-rgb), 0.75);',
            "    font-family: 'Metropolis', 'Open Sans', sans-serif;",
            '    font-size: 16px;',
            '    font-weight: 700;',
            '    line-height: 20px;',
            '    letter-spacing: 0.01em;',
            '    white-space: nowrap;',
            '}',
            '.hfroute-header .header-logo-link[' + LOGIN_ROOT_ATTRIBUTE + '] > svg {',
            '    display: none !important;',
            '}',
            '.hfroute-header .' + LOGIN_BRAND_CLASS + ' {',
            '    display: inline-flex;',
            '    align-items: center;',
            '    color: var(--center-channel-color);',
            "    font-family: 'Metropolis', 'Open Sans', sans-serif;",
            '    font-size: 28px;',
            '    font-weight: 700;',
            '    line-height: 32px;',
            '    letter-spacing: 0.01em;',
            '    white-space: nowrap;',
            '}',
            '.hfroute-header .header-logo-link[' + HIDDEN_SITE_ATTRIBUTE + '] {',
            '    display: none !important;',
            '}'
        ].join('\n');
        document.head.appendChild(style);
    }

    function findMattermostWordmark(button) {
        var logos = button.querySelectorAll('span > svg');
        for (var i = 0; i < logos.length; i += 1) {
            var logo = logos[i];
            if (logo.parentElement && logo.parentElement.parentElement === button) {
                return logo;
            }
        }
        return null;
    }

    function applyChannelsWordmark() {
        var button = document.getElementById('product_switch_menu');
        if (!button) {
            return;
        }
        var originalLogo = findMattermostWordmark(button);
        if (!originalLogo || !originalLogo.parentElement) {
            return;
        }
        var root = originalLogo.parentElement;
        root.setAttribute(CHANNEL_ROOT_ATTRIBUTE, 'true');
        if (root.querySelector('.' + CHANNEL_BRAND_CLASS)) {
            return;
        }
        var wordmark = document.createElement('span');
        wordmark.className = CHANNEL_BRAND_CLASS;
        wordmark.textContent = BRAND_TEXT;
        wordmark.setAttribute('aria-label', BRAND_TEXT);
        root.insertBefore(wordmark, originalLogo);
    }

    function rememberAndReplaceAriaLabel(link) {
        if (!link.hasAttribute(ORIGINAL_ARIA_ATTRIBUTE)) {
            link.setAttribute(ORIGINAL_ARIA_ATTRIBUTE, link.getAttribute('aria-label') || '');
        }
        link.setAttribute('aria-label', BRAND_TEXT);
    }

    function replaceEditionLabel(element) {
        if (element.textContent.trim() === EDITION_TEXT) {
            return;
        }
        if (!element.hasAttribute(ORIGINAL_EDITION_ATTRIBUTE)) {
            element.setAttribute(ORIGINAL_EDITION_ATTRIBUTE, element.textContent.trim());
        }
        element.textContent = EDITION_TEXT;
    }

    function applyEditionLabels() {
        var loginBadges = document.querySelectorAll('.hfroute-header .freeBadge');
        for (var i = 0; i < loginBadges.length; i += 1) {
            replaceEditionLabel(loginBadges[i]);
        }

        var button = document.getElementById('product_switch_menu');
        if (!button) {
            return;
        }

        var candidates = button.querySelectorAll('span, div');
        for (var j = 0; j < candidates.length; j += 1) {
            var candidate = candidates[j];
            var isOriginalEdition = candidate.textContent.trim() === 'ENTRY EDITION';
            var isManagedEdition = candidate.hasAttribute(ORIGINAL_EDITION_ATTRIBUTE);
            if (candidate.children.length === 0 && (isOriginalEdition || isManagedEdition)) {
                replaceEditionLabel(candidate);
            }
        }
    }

    function applyLoginWordmark() {
        var header = document.querySelector('.hfroute-header');
        if (!header) {
            return;
        }
        var links = header.querySelectorAll('.header-logo-link');
        var primaryLink = null;
        for (var i = 0; i < links.length; i += 1) {
            if (links[i].querySelector('svg') && links[i].querySelector('.freeBadge')) {
                primaryLink = links[i];
                break;
            }
        }
        if (!primaryLink) {
            return;
        }
        primaryLink.setAttribute(LOGIN_ROOT_ATTRIBUTE, 'true');
        rememberAndReplaceAriaLabel(primaryLink);
        if (!primaryLink.querySelector('.' + LOGIN_BRAND_CLASS)) {
            var originalLogo = primaryLink.querySelector('svg');
            var wordmark = document.createElement('span');
            wordmark.className = LOGIN_BRAND_CLASS;
            wordmark.textContent = BRAND_TEXT;
            wordmark.setAttribute('aria-hidden', 'true');
            primaryLink.insertBefore(wordmark, originalLogo);
        }
        for (var j = 0; j < links.length; j += 1) {
            var link = links[j];
            if (link !== primaryLink && !link.querySelector('svg') && !link.querySelector('.freeBadge') && (link.textContent.trim() === BRAND_TEXT || link.textContent.trim() === 'GIST')) {
                link.setAttribute(HIDDEN_SITE_ATTRIBUTE, 'true');
            }
        }
    }

    function removeWordmarks() {
        var wordmarks = document.querySelectorAll('.' + CHANNEL_BRAND_CLASS + ', .' + LOGIN_BRAND_CLASS);
        for (var i = 0; i < wordmarks.length; i += 1) {
            wordmarks[i].remove();
        }
        var channelRoots = document.querySelectorAll('[' + CHANNEL_ROOT_ATTRIBUTE + ']');
        for (var j = 0; j < channelRoots.length; j += 1) {
            channelRoots[j].removeAttribute(CHANNEL_ROOT_ATTRIBUTE);
        }
        var loginRoots = document.querySelectorAll('[' + LOGIN_ROOT_ATTRIBUTE + ']');
        for (var k = 0; k < loginRoots.length; k += 1) {
            var originalAriaLabel = loginRoots[k].getAttribute(ORIGINAL_ARIA_ATTRIBUTE);
            if (originalAriaLabel) {
                loginRoots[k].setAttribute('aria-label', originalAriaLabel);
            } else {
                loginRoots[k].removeAttribute('aria-label');
            }
            loginRoots[k].removeAttribute(ORIGINAL_ARIA_ATTRIBUTE);
            loginRoots[k].removeAttribute(LOGIN_ROOT_ATTRIBUTE);
        }
        var hiddenSiteNames = document.querySelectorAll('[' + HIDDEN_SITE_ATTRIBUTE + ']');
        for (var m = 0; m < hiddenSiteNames.length; m += 1) {
            hiddenSiteNames[m].removeAttribute(HIDDEN_SITE_ATTRIBUTE);
        }
        var editionLabels = document.querySelectorAll('[' + ORIGINAL_EDITION_ATTRIBUTE + ']');
        for (var n = 0; n < editionLabels.length; n += 1) {
            editionLabels[n].textContent = editionLabels[n].getAttribute(ORIGINAL_EDITION_ATTRIBUTE);
            editionLabels[n].removeAttribute(ORIGINAL_EDITION_ATTRIBUTE);
        }
        var style = document.getElementById(STYLE_ID);
        if (style) {
            style.remove();
        }
    }

    function applyBranding() {
        applyChannelsWordmark();
        applyLoginWordmark();
        applyEditionLabels();
    }

    function Plugin() {
        this.observer = null;
        this.frame = null;
    }

    Plugin.prototype.initialize = function () {
        var self = this;
        installStyle();
        applyBranding();
        this.observer = new MutationObserver(function () {
            if (self.frame !== null) {
                return;
            }
            self.frame = window.requestAnimationFrame(function () {
                self.frame = null;
                applyBranding();
            });
        });
        this.observer.observe(document.body, {childList: true, subtree: true});
    };

    Plugin.prototype.uninitialize = function () {
        if (this.observer) {
            this.observer.disconnect();
            this.observer = null;
        }
        if (this.frame !== null) {
            window.cancelAnimationFrame(this.frame);
            this.frame = null;
        }
        removeWordmarks();
    };

    window.registerPlugin(PLUGIN_ID, new Plugin());
}());
