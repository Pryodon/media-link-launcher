'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const SCRIPT_PATH = path.resolve(__dirname, '..', 'media-link-launcher.user.js');

class FakeNode {
    constructor() {
        this.parentNode = null;
    }

    get isConnected() {
        let current = this;
        while (current) {
            if (current instanceof FakeDocument) {
                return true;
            }
            current = current.parentNode;
        }
        return false;
    }

    remove() {
        if (!this.parentNode) {
            return;
        }
        const siblings = this.parentNode.childNodes;
        const index = siblings.indexOf(this);
        if (index >= 0) {
            siblings.splice(index, 1);
        }
        this.parentNode = null;
    }
}

class FakeTextNode extends FakeNode {
    constructor(text) {
        super();
        this.textContent = text;
    }
}

class FakeStyle {
    constructor() {
        this.values = new Map();
    }

    setProperty(name, value, priority) {
        this.values.set(name, {value, priority});
    }
}

class FakeElement extends FakeNode {
    constructor(tagName) {
        super();
        this.tagName = tagName.toUpperCase();
        this.attributes = new Map();
        this.childNodes = [];
        this.className = '';
        this.style = new FakeStyle();
        this.listeners = new Map();
        this._textContent = '';
    }

    get textContent() {
        if (this._textContent) {
            return this._textContent;
        }
        return this.childNodes.map(node => node.textContent || '').join('');
    }

    set textContent(value) {
        this._textContent = String(value);
    }

    setAttribute(name, value) {
        this.attributes.set(name, String(value));
    }

    getAttribute(name) {
        return this.attributes.has(name) ? this.attributes.get(name) : null;
    }

    hasAttribute(name) {
        return this.attributes.has(name);
    }

    append(...nodes) {
        for (const node of nodes) {
            const value = typeof node === 'string' ? new FakeTextNode(node) : node;
            value.parentNode = this;
            this.childNodes.push(value);
        }
    }

    insertAdjacentElement(position, element) {
        assert.equal(position, 'afterend');
        assert.ok(this.parentNode);
        const siblings = this.parentNode.childNodes;
        const index = siblings.indexOf(this);
        element.parentNode = this.parentNode;
        siblings.splice(index + 1, 0, element);
        return element;
    }

    addEventListener(type, listener) {
        this.listeners.set(type, listener);
    }

    querySelectorAll(selector) {
        const result = [];
        const visit = node => {
            if (!(node instanceof FakeElement)) {
                return;
            }
            if (selector === 'a[href]' &&
                node instanceof FakeHTMLAnchorElement &&
                node.hasAttribute('href')) {
                result.push(node);
            }
            for (const child of node.childNodes) {
                visit(child);
            }
        };
        for (const child of this.childNodes) {
            visit(child);
        }
        return result;
    }
}

class FakeHTMLAnchorElement extends FakeElement {
    constructor() {
        super('a');
    }
}

class FakeDocumentFragment extends FakeElement {
    constructor() {
        super('#fragment');
    }
}

class FakeDocument extends FakeElement {
    constructor() {
        super('#document');
        this.baseURI = 'https://example.test/base/page.html';
        this.documentElement = new FakeElement('html');
        this.head = new FakeElement('head');
        this.body = new FakeElement('body');
        this.append(this.documentElement);
        this.documentElement.append(this.head, this.body);
    }

    createElement(tagName) {
        if (tagName.toLowerCase() === 'a') {
            return new FakeHTMLAnchorElement();
        }
        return new FakeElement(tagName);
    }

    createTextNode(text) {
        return new FakeTextNode(text);
    }
}

class FakeMutationObserver {
    constructor(callback) {
        this.callback = callback;
        this.options = null;
        FakeMutationObserver.instance = this;
    }

    observe(_target, options) {
        this.options = options;
    }
}

function elementsWithClass(root, className) {
    const result = [];
    const visit = node => {
        if (!(node instanceof FakeElement)) {
            return;
        }
        if (node.className.split(/\s+/).includes(className)) {
            result.push(node);
        }
        node.childNodes.forEach(visit);
    };
    visit(root);
    return result;
}

function anchor(document, href, text, attributes = {}) {
    const element = document.createElement('a');
    element.setAttribute('href', href);
    element.textContent = text;
    for (const [name, value] of Object.entries(attributes)) {
        element.setAttribute(name, value);
    }
    return element;
}

function executeUserscript(document) {
    const navigations = [];
    const context = {
        URL,
        decodeURIComponent,
        encodeURIComponent,
        document,
        Document: FakeDocument,
        DocumentFragment: FakeDocumentFragment,
        Element: FakeElement,
        HTMLAnchorElement: FakeHTMLAnchorElement,
        MutationObserver: FakeMutationObserver,
        window: {
            getComputedStyle: () => ({color: 'rgb(1, 2, 3)'}),
            location: {assign: value => navigations.push(value)},
        },
    };
    vm.runInNewContext(fs.readFileSync(SCRIPT_PATH, 'utf8'), context, {
        filename: SCRIPT_PATH,
    });
    return {navigations, observer: FakeMutationObserver.instance};
}

test('initial scan preserves original links and avoids title-only false positives', () => {
    const document = new FakeDocument();
    const mediaHref = '/video/a b-café%25.mp4?token=a%26b&expires=9#part';
    const media = anchor(document, mediaHref, 'Watch');
    const chatTitle = anchor(
        document,
        'https://chatgpt.com/c/1234',
        'An ordinary conversation title .mp4',
    );
    const download = anchor(document, '/download?id=8', 'recording.mp4', {download: ''});
    document.body.append(media, chatTitle, download);

    const {navigations} = executeUserscript(document);
    const wrappers = elementsWithClass(document, 'media-link-launcher-wrapper');
    assert.equal(wrappers.length, 2);
    assert.equal(media.getAttribute('href'), mediaHref);
    assert.equal(chatTitle.getAttribute('href'), 'https://chatgpt.com/c/1234');
    assert.equal(download.getAttribute('href'), '/download?id=8');

    const control = wrappers[0].childNodes.find(
        node => node instanceof FakeElement && node.tagName === 'BUTTON',
    );
    assert.ok(control);
    assert.equal(control.textContent, 'VLC');

    const ignoredEvent = {
        isTrusted: false,
        button: 0,
        preventDefault() {},
        stopImmediatePropagation() {},
    };
    control.listeners.get('click')(ignoredEvent);
    assert.deepEqual(navigations, []);

    const trustedEvent = {...ignoredEvent, isTrusted: true};
    control.listeners.get('click')(trustedEvent);
    assert.equal(navigations.length, 1);
    assert.ok(navigations[0].startsWith('media-link-launcher://open?url='));
    const target = decodeURIComponent(navigations[0].split('url=', 2)[1]);
    assert.equal(target, new URL(mediaHref, document.baseURI).href);
});

test('dynamic insertion is detected and repeated scans do not create duplicates', () => {
    const document = new FakeDocument();
    const {observer} = executeUserscript(document);
    assert.ok(observer);
    assert.deepEqual(
        Array.from(observer.options.attributeFilter),
        ['href', 'type', 'download'],
    );

    const dynamic = anchor(document, '/streams/live.m3u8?sig=a%2Bb', 'Live');
    document.body.append(dynamic);
    const mutation = {type: 'childList', addedNodes: [dynamic]};
    observer.callback([mutation]);
    observer.callback([mutation]);
    observer.callback([{type: 'attributes', target: dynamic}]);
    assert.equal(elementsWithClass(document, 'media-link-launcher-wrapper').length, 1);

    dynamic.setAttribute('href', '/ordinary/page');
    observer.callback([{type: 'attributes', target: dynamic}]);
    assert.equal(elementsWithClass(document, 'media-link-launcher-wrapper').length, 0);
});

test('MIME, query-parameter, and direct-protocol heuristics remain available', () => {
    const document = new FakeDocument();
    document.body.append(
        anchor(document, '/opaque/1', 'Typed media', {type: 'video/mp4; charset=binary'}),
        anchor(document, '/get?source=movie.webm&signed=a%26b', 'Query media'),
        anchor(document, 'rtsp://camera.example/live', 'Camera'),
        anchor(document, 'file:///tmp/movie.mp4', 'Blocked local file'),
    );
    executeUserscript(document);
    assert.equal(elementsWithClass(document, 'media-link-launcher-wrapper').length, 3);
});
