// ==UserScript==
// @name         Media Link Launcher
// @namespace    media-link-launcher.local
// @version      0.2.1
// @description  Adds a user-activated VLC control beside heuristically recognized media links without changing the original link.
// @match        *://*/*
// @run-at       document-idle
// @sandbox      DOM
// @grant        none
// ==/UserScript==

(() => {
    'use strict';

    /*
     * The website's original anchor is never modified. The complete absolute
     * media URL remains in this isolated userscript closure and is encoded into
     * the custom-protocol request only after a trusted left click.
     */

    const HTML_NAMESPACE = 'http://www.w3.org/1999/xhtml';

    const MEDIA_EXTENSIONS = new Set([
        // Video
        '3g2', '3gp', '3gp2', '3gpp', 'amv', 'asf', 'avi', 'bik', 'divx',
        'dv', 'f4v', 'flv', 'gvi', 'gxf', 'm1v', 'm2t', 'm2ts', 'm2v',
        'm4v', 'mkv', 'mov', 'mp2v', 'mp4', 'mpe', 'mpeg', 'mpg', 'mpv2',
        'mts', 'mxf', 'nsv', 'ogm', 'ogv', 'qt', 'rm', 'rmvb', 'roq', 'ts',
        'vob', 'webm', 'wmv',

        // Audio
        '8svx', 'aac', 'ac3', 'aiff', 'alac', 'amr', 'ape', 'au', 'caf',
        'dts', 'eac3', 'flac', 'it', 'm4a', 'm4b', 'mka', 'mlp', 'mod',
        'mp2', 'mp3', 'mpc', 'oga', 'ogg', 'oma', 'opus', 'ra', 's3m',
        'spx', 'tak', 'tta', 'voc', 'wav', 'wma', 'wv', 'xm',

        // Playlists and streaming manifests
        'asx', 'cue', 'm3u', 'm3u8', 'mpd', 'pls', 'ram', 'sdp', 'smil',
        'xspf',
    ]);

    const DIRECT_STREAM_PROTOCOLS = new Set([
        'rtsp:', 'rtsps:', 'rtmp:', 'rtmps:', 'mms:', 'mmsh:', 'mmst:',
        'rtp:', 'udp:',
    ]);

    const WEB_PROTOCOLS = new Set([
        'http:', 'https:', 'ftp:', 'ftps:', 'sftp:', 'smb:',
    ]);

    const EXTRA_MEDIA_MIME_TYPES = new Set([
        'application/dash+xml',
        'application/ogg',
        'application/vnd.apple.mpegurl',
        'application/x-mpegurl',
        'application/mpegurl',
        'application/xspf+xml',
    ]);

    const generatedControls = new WeakMap();

    function createHtmlElement(tagName) {
        return document.createElementNS(HTML_NAMESPACE, tagName);
    }

    function isAnchorElement(node) {
        return node instanceof Element &&
            node.localName === 'a' &&
            (node.namespaceURI === null || node.namespaceURI === HTML_NAMESPACE);
    }

    function installStyles() {
        const style = createHtmlElement('style');
        style.textContent = `
            .media-link-launcher-wrapper {
                white-space: nowrap !important;
            }
            .media-link-launcher-control {
                appearance: none !important;
                background: none !important;
                border: 0 !important;
                color: inherit !important;
                cursor: pointer !important;
                display: inline !important;
                font: inherit !important;
                font-weight: 700 !important;
                margin: 0 0 0 0.25em !important;
                padding: 0 !important;
                text-decoration: underline !important;
            }
        `;
        (document.head || document.documentElement).append(style);
    }

    function extensionFromText(value) {
        if (!value) {
            return '';
        }

        let decoded = value;
        try {
            decoded = decodeURIComponent(value);
        } catch {
            // Keep the undecoded value when a literal percent sign is present.
        }

        const match = decoded.trim().toLowerCase().match(/\.([a-z0-9]{2,8})(?:[?#].*)?$/);
        return match ? match[1] : '';
    }

    function hasRecognizedExtension(value) {
        return MEDIA_EXTENSIONS.has(extensionFromText(value));
    }

    function hasMediaMimeType(anchor) {
        const type = (anchor.getAttribute('type') || '')
            .split(';', 1)[0]
            .trim()
            .toLowerCase();

        return type.startsWith('audio/') ||
            type.startsWith('video/') ||
            EXTRA_MEDIA_MIME_TYPES.has(type);
    }

    function hasDownloadMediaHint(anchor) {
        if (!anchor.hasAttribute('download')) {
            return false;
        }

        const downloadName = anchor.getAttribute('download') || '';
        if (hasRecognizedExtension(downloadName)) {
            return true;
        }

        /*
         * Visible text is only a supporting signal when the page also marks the
         * anchor as a download. This avoids treating ordinary linked titles such
         * as a ChatGPT conversation ending in ".mp4" as direct media.
         */
        const text = (anchor.textContent || '').trim();
        return text.length > 0 && text.length <= 512 && hasRecognizedExtension(text);
    }

    function findMediaTarget(anchor) {
        const rawHref = anchor.getAttribute('href');
        if (!rawHref || rawHref.startsWith('#')) {
            return null;
        }

        let url;
        try {
            url = new URL(rawHref, document.baseURI);
        } catch {
            return null;
        }

        if (DIRECT_STREAM_PROTOCOLS.has(url.protocol)) {
            return url.href;
        }
        if (!WEB_PROTOCOLS.has(url.protocol)) {
            return null;
        }

        if (hasMediaMimeType(anchor) ||
            hasRecognizedExtension(url.pathname) ||
            hasDownloadMediaHint(anchor)) {
            return url.href;
        }

        for (const [, value] of url.searchParams) {
            if (hasRecognizedExtension(value)) {
                return url.href;
            }
        }

        return null;
    }

    function makeLauncherUri(mediaUrl) {
        return `media-link-launcher://open?url=${encodeURIComponent(mediaUrl)}`;
    }

    function processAnchor(anchor) {
        if (!isAnchorElement(anchor)) {
            return;
        }

        const mediaUrl = findMediaTarget(anchor);
        const previous = generatedControls.get(anchor);

        if (!mediaUrl) {
            if (previous) {
                previous.wrapper.remove();
                generatedControls.delete(anchor);
            }
            return;
        }

        if (previous && previous.mediaUrl === mediaUrl && previous.wrapper.isConnected) {
            return;
        }

        if (previous) {
            previous.wrapper.remove();
        }

        const wrapper = createHtmlElement('span');
        wrapper.className = 'media-link-launcher-wrapper';
        wrapper.style.setProperty(
            'color',
            window.getComputedStyle(anchor).color,
            'important',
        );

        const separator = document.createTextNode(' ');
        const control = createHtmlElement('button');
        control.type = 'button';
        control.className = 'media-link-launcher-control';
        control.textContent = 'VLC';
        control.title = 'Open this media link in VLC media player (confirmation required)';
        control.setAttribute('aria-label', control.title);

        control.addEventListener('click', event => {
            event.preventDefault();
            event.stopImmediatePropagation();
            if (!event.isTrusted || event.button !== 0) {
                return;
            }
            window.location.assign(makeLauncherUri(mediaUrl));
        }, true);

        wrapper.append(separator, control);
        anchor.insertAdjacentElement('afterend', wrapper);
        generatedControls.set(anchor, {wrapper, mediaUrl});
    }

    function scan(root) {
        if (isAnchorElement(root)) {
            processAnchor(root);
        }

        if (root instanceof Element || root instanceof Document ||
            root instanceof DocumentFragment) {
            root.querySelectorAll?.('a[href]').forEach(processAnchor);
        }
    }

    installStyles();
    scan(document);

    const observer = new MutationObserver(mutations => {
        for (const mutation of mutations) {
            if (mutation.type === 'attributes') {
                processAnchor(mutation.target);
                continue;
            }

            for (const node of mutation.addedNodes) {
                if (node instanceof Element || node instanceof DocumentFragment) {
                    scan(node);
                }
            }
        }
    });

    observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'type', 'download'],
    });
})();
