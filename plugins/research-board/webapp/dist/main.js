(function () {
    'use strict';
    var ID = 'com.hermes.research-board';
    var ROOT = '/plugins/' + ID;
    var React = window.React;
    var ReactDOM = window.ReactDOM;
    function channelURL(info) {
        var query = new URLSearchParams(window.location.search);
        query.set('research_board', '1');
        return info.channel_url + '?' + query.toString();
    }
    function access() {
        return window.fetch(ROOT + '/access', {credentials: 'same-origin'}).then(function (r) {
            if (!r.ok) { throw new Error('연구 보드 열람 권한 또는 마법사 연결 설정을 확인하세요.'); }
            return r.json();
        });
    }
    function Link() {
        var state = React.useState(null), info = state[0], set = state[1];
        React.useEffect(function () { var active = true; access().then(function (x) { if (active) { set(x); } }).catch(function () {}); return function () { active = false; }; }, []);
        if (!info) { return null; }
        return React.createElement('a', {href: channelURL(info), className: 'SidebarChannel', 'aria-label': '한국어 연구 작업보드 열기', style: {display: 'block', padding: '12px 16px', color: 'var(--sidebar-text)', fontWeight: 600}}, '▦  연구 작업보드');
    }
    function Board() {
        var state = React.useState({loading: true}), info = state[0], set = state[1];
        React.useEffect(function () { var active = true; access().then(function (x) { if (active) { set(x); } }).catch(function (e) { if (active) { set({error: e.message}); } }); return function () { active = false; }; }, []);
        var content;
        if (info.loading || info.error) { content = React.createElement('p', {role: 'status', style: {padding: 24}}, info.error || '연구 보드 연결을 확인합니다…'); }
        else { content = React.createElement('iframe', {title: '한국어 연구 작업보드', src: ROOT + '/board/' + window.location.search, sandbox: 'allow-scripts allow-same-origin allow-downloads', referrerPolicy: 'no-referrer', style: {width: '100%', flex: '1 1 auto', border: 0, minHeight: 0}}); }
        return React.createElement('section', {style: {display: 'flex', flexDirection: 'column', height: '100%', width: '100%', minWidth: 0, background: 'var(--center-channel-bg)'}},
            React.createElement('header', {style: {padding: '12px 20px', borderBottom: '1px solid var(--center-channel-color-16)'}},
                React.createElement('strong', null, '연구 작업보드'),
                info.channel_url ? React.createElement('a', {href: info.channel_url, style: {marginLeft: 24}}, '연구 채널로 돌아가기') : null), content);
    }
    function Entry() {
        React.useEffect(function () { var active = true; access().then(function (x) { if (active) { window.location.replace(channelURL(x)); } }).catch(function () {}); return function () { active = false; }; }, []);
        return React.createElement('p', {style: {gridColumn: '1 / -1', padding: 24}}, '연구 채널 안에서 작업보드를 여는 중입니다. 로그인·열람 권한이 필요합니다.');
    }
    // The supported root-component extension keeps Mattermost's own channel
    // sidebar/header shell. Only the channel center is covered, not a modal
    // over the whole app. All DOM changes are scoped and restored on close.
    function Dock() {
        var state = React.useState(null), host = state[0], setHost = state[1];
        React.useEffect(function () {
            var cleanup = null, current = null;
            function sync() {
                var enabled = new URLSearchParams(window.location.search).get('research_board') === '1';
                var target = enabled ? document.getElementById('app-content') : null;
                if (current && current.parentNode === target) { return; }
                if (cleanup) { cleanup(); cleanup = null; current = null; setHost(null); }
                if (!target) { return; }
                var position = target.style.position;
                var prior = Array.prototype.map.call(target.children, function (node) { return {node: node, visibility: node.style.visibility, hidden: node.getAttribute('aria-hidden'), inert: node.inert}; });
                target.style.position = 'relative';
                prior.forEach(function (x) { x.node.style.visibility = 'hidden'; x.node.setAttribute('aria-hidden', 'true'); x.node.inert = true; });
                var panel = document.createElement('div');
                panel.setAttribute('data-hermes-board', 'true');
                panel.style.cssText = 'position:absolute;inset:0;z-index:10;display:flex;min-width:0;min-height:0;background:var(--center-channel-bg)';
                target.appendChild(panel); current = panel; setHost(panel);
                cleanup = function () {
                    if (panel.parentNode) { panel.parentNode.removeChild(panel); }
                    target.style.position = position;
                    prior.forEach(function (x) { x.node.style.visibility = x.visibility; x.node.inert = x.inert; if (x.hidden === null) { x.node.removeAttribute('aria-hidden'); } else { x.node.setAttribute('aria-hidden', x.hidden); } });
                };
            }
            sync();
            var timer = window.setInterval(sync, 250);
            window.addEventListener('popstate', sync);
            return function () { window.clearInterval(timer); window.removeEventListener('popstate', sync); if (cleanup) { cleanup(); } };
        }, []);
        return host ? ReactDOM.createPortal(React.createElement(Board), host) : null;
    }
    function Plugin() { this.components = []; }
    Plugin.prototype.initialize = function (registry) {
        this.registry = registry;
        this.components.push(registry.registerNeedsTeamRoute('/board', Entry));
        this.components.push(registry.registerCustomRoute('/board', Entry));
        this.components.push(registry.registerRootComponent(Dock));
        this.components.push(registry.registerLeftSidebarHeaderComponent(Link));
        this.components.push(registry.registerChannelHeaderButtonAction(React.createElement('span', null, '▦'), function () { access().then(function (x) { window.location.assign(channelURL(x)); }).catch(function () {}); }, '연구 작업보드', '한국어 연구 작업보드 열기'));
    };
    Plugin.prototype.uninitialize = function () {
        var registry = this.registry;
        this.components.forEach(function (id) { if (id) { registry.unregisterComponent(id); } });
        this.components = [];
    };
    window.registerPlugin(ID, new Plugin());
}());
