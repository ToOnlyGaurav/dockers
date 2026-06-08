(function() {
    'use strict';

    const API = '/api';
    let databases = [];
    let currentDb = null;

    // --- DOM refs ---
    const dropdown = document.getElementById('db-dropdown');
    const healthSpan = document.getElementById('db-health');
    const refreshBtn = document.getElementById('refresh-btn');
    const noSelection = document.getElementById('no-selection');
    const dbPanel = document.getElementById('db-panel');
    const dbStatus = document.getElementById('db-status');
    const capsBar = document.getElementById('capabilities-bar');
    const actionArea = document.getElementById('action-area');
    const resultArea = document.getElementById('result-area');
    const resultContent = document.getElementById('result-content');
    const clearResult = document.getElementById('clear-result');

    // --- Action definitions per capability ---
    const CAP_ACTIONS = {
        crud: ['read', 'write', 'delete'],
        browse: ['list', 'describe'],
        query: ['query'],
        pubsub: ['publish', 'consume']
    };

    const ACTION_LABELS = {
        read: 'Read', write: 'Write', delete: 'Delete',
        list: 'List Entities', describe: 'Describe Entity',
        query: 'Execute Query', publish: 'Publish', consume: 'Consume'
    };

    // --- Init ---
    refreshBtn.addEventListener('click', loadDatabases);
    clearResult.addEventListener('click', () => {
        resultArea.classList.add('hidden');
        resultContent.textContent = '';
    });
    dropdown.addEventListener('change', onDbSelected);
    loadDatabases();

    async function loadDatabases() {
        dropdown.innerHTML = '<option value="">-- Loading... --</option>';
        healthSpan.textContent = '';
        try {
            const resp = await fetch(API + '/databases');
            databases = await resp.json();
            dropdown.innerHTML = '<option value="">-- Select Database --</option>';
            databases.forEach(db => {
                const opt = document.createElement('option');
                opt.value = db.name;
                opt.textContent = db.name + (db.healthy ? ' (up)' : ' (down)');
                dropdown.appendChild(opt);
            });
            // Re-select current if still present
            if (currentDb) {
                dropdown.value = currentDb.name;
                onDbSelected();
            }
        } catch (e) {
            dropdown.innerHTML = '<option value="">-- Error loading --</option>';
        }
    }

    async function onDbSelected() {
        const name = dropdown.value;
        if (!name) {
            noSelection.classList.remove('hidden');
            dbPanel.classList.add('hidden');
            currentDb = null;
            return;
        }
        
        // Show loading state
        noSelection.classList.add('hidden');
        dbPanel.classList.remove('hidden');
        dbStatus.textContent = 'Connecting...';
        dbStatus.className = '';
        healthSpan.textContent = 'Connecting...';
        capsBar.innerHTML = '<span style="color:#999">Loading...</span>';
        actionArea.innerHTML = '';
        
        // Fetch database details (this triggers connection check)
        try {
            const resp = await fetch(API + '/databases/' + name);
            currentDb = await resp.json();
            renderDbPanel();
        } catch (e) {
            dbStatus.textContent = 'Error loading database: ' + e.message;
            dbStatus.className = 'unhealthy';
            healthSpan.textContent = 'Error';
        }
    }

    function renderDbPanel() {
        const db = currentDb;
        
        // Special handling for ZooKeeper - use custom browser
        if (db.name === 'zk' && window.ZkBrowser) {
            dbStatus.textContent = db.statusMessage;
            dbStatus.className = db.healthy ? 'healthy' : 'unhealthy';
            healthSpan.textContent = db.healthy ? 'Connected' : 'Disconnected';
            capsBar.innerHTML = '';
            actionArea.innerHTML = '';
            
            if (db.healthy) {
                window.ZkBrowser.render(actionArea);
            } else {
                actionArea.innerHTML = '<p style="color:#999;text-align:center;padding:20px;">Cannot connect to ZooKeeper</p>';
            }
            resultArea.classList.add('hidden');
            return;
        }
        
        // Special handling for MariaDB - use custom browser
        if (db.name === 'mariadb' && window.MariaDbBrowser) {
            dbStatus.textContent = db.statusMessage;
            dbStatus.className = db.healthy ? 'healthy' : 'unhealthy';
            healthSpan.textContent = db.healthy ? 'Connected' : 'Disconnected';
            capsBar.innerHTML = '';
            actionArea.innerHTML = '';
            
            if (db.healthy) {
                window.MariaDbBrowser.render(actionArea);
            } else {
                actionArea.innerHTML = '<p style="color:#999;text-align:center;padding:20px;">Cannot connect to MariaDB</p>';
            }
            resultArea.classList.add('hidden');
            return;
        }
        
        // Special handling for Aerospike - use custom browser
        if (db.name === 'aerospike' && window.AerospikeDbBrowser) {
            dbStatus.textContent = db.statusMessage;
            dbStatus.className = db.healthy ? 'healthy' : 'unhealthy';
            healthSpan.textContent = db.healthy ? 'Connected' : 'Disconnected';
            capsBar.innerHTML = '';
            actionArea.innerHTML = '';
            
            if (db.healthy) {
                window.AerospikeDbBrowser.render(actionArea);
            } else {
                actionArea.innerHTML = '<p style="color:#999;text-align:center;padding:20px;">Cannot connect to Aerospike</p>';
            }
            resultArea.classList.add('hidden');
            return;
        }
        
        // Special handling for Docker Registry - use custom browser
        if (db.name === 'docker-registry' && window.DockerRegistryBrowser) {
            dbStatus.textContent = db.statusMessage;
            dbStatus.className = db.healthy ? 'healthy' : 'unhealthy';
            healthSpan.textContent = db.healthy ? 'Connected' : 'Disconnected';
            capsBar.innerHTML = '';
            actionArea.innerHTML = '';
            
            if (db.healthy) {
                window.DockerRegistryBrowser.render(actionArea);
            } else {
                actionArea.innerHTML = '<p style="color:#999;text-align:center;padding:20px;">Cannot connect to Docker Registry</p>';
            }
            resultArea.classList.add('hidden');
            return;
        }
        
        // Regular database panel rendering
        // Status
        dbStatus.textContent = db.statusMessage;
        dbStatus.className = db.healthy ? 'healthy' : 'unhealthy';
        healthSpan.textContent = db.healthy ? 'Connected' : 'Disconnected';

        // Capability buttons
        capsBar.innerHTML = '';
        const caps = db.capabilities || [];
        if (caps.length === 0) {
            capsBar.innerHTML = '<span style="color:#999">No capabilities available</span>';
            actionArea.innerHTML = '';
            return;
        }
        caps.forEach((cap, i) => {
            const btn = document.createElement('button');
            btn.className = 'cap-btn' + (i === 0 ? ' active' : '');
            btn.textContent = capLabel(cap);
            btn.dataset.cap = cap;
            btn.addEventListener('click', () => {
                capsBar.querySelectorAll('.cap-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                renderActions(cap);
            });
            capsBar.appendChild(btn);
        });

        // Render first capability by default
        renderActions(caps[0]);
    }

    function capLabel(cap) {
        return { crud: 'CRUD', browse: 'Browse', query: 'Query', pubsub: 'Pub/Sub' }[cap] || cap;
    }

    function renderActions(cap) {
        const actions = CAP_ACTIONS[cap] || [];
        actionArea.innerHTML = '';

        if (actions.length === 0) return;

        // Tabs for actions within this capability
        const tabs = document.createElement('div');
        tabs.className = 'action-tabs';
        const formContainer = document.createElement('div');

        actions.forEach((action, i) => {
            const tab = document.createElement('button');
            tab.className = 'action-tab' + (i === 0 ? ' active' : '');
            tab.textContent = ACTION_LABELS[action] || action;
            tab.addEventListener('click', () => {
                tabs.querySelectorAll('.action-tab').forEach(t => t.classList.remove('active'));
                tab.classList.add('active');
                renderActionForm(formContainer, action);
            });
            tabs.appendChild(tab);
        });

        actionArea.appendChild(tabs);
        actionArea.appendChild(formContainer);
        renderActionForm(formContainer, actions[0]);
    }

    function renderActionForm(container, action) {
        container.innerHTML = '';
        const db = currentDb;
        const paramDefs = (db.actionParams && db.actionParams[action]) || [];

        // Build param fields
        paramDefs.forEach(p => {
            const group = document.createElement('div');
            group.className = 'form-group';
            const label = document.createElement('label');
            label.textContent = p.label + (p.required ? ' *' : '');
            group.appendChild(label);

            if (p.type === 'textarea') {
                const ta = document.createElement('textarea');
                ta.name = p.name;
                ta.placeholder = p.label;
                ta.value = p.defaultValue || '';
                group.appendChild(ta);
            } else {
                const input = document.createElement('input');
                input.type = p.type === 'number' ? 'number' : 'text';
                input.name = p.name;
                input.placeholder = p.label;
                input.value = p.defaultValue || '';
                group.appendChild(input);
            }
            container.appendChild(group);
        });

        // For write actions, add a JSON value editor
        if (action === 'write') {
            const editor = document.createElement('div');
            editor.className = 'value-editor';
            editor.innerHTML = '<h5>Value (JSON object)</h5>';
            const ta = document.createElement('textarea');
            ta.name = '__value__';
            ta.placeholder = '{"field1": "value1", "field2": 123}';
            ta.value = '{}';
            editor.appendChild(ta);
            container.appendChild(editor);
        }

        // Execute button
        const btn = document.createElement('button');
        btn.className = 'execute-btn' + (action === 'delete' ? ' danger' : '');
        btn.textContent = (ACTION_LABELS[action] || action);
        btn.addEventListener('click', () => executeAction(container, action));
        container.appendChild(btn);
    }

    async function executeAction(container, action) {
        const db = currentDb;
        const paramDefs = (db.actionParams && db.actionParams[action]) || [];

        // Collect params
        const params = {};
        const payload = { action: action };

        paramDefs.forEach(p => {
            const el = container.querySelector('[name="' + p.name + '"]');
            if (el) {
                // Certain fields go directly on payload, not in params
                if (['query', 'target', 'message', 'maxMessages', 'entity'].includes(p.name)) {
                    payload[p.name] = p.type === 'number' ? parseInt(el.value, 10) : el.value;
                } else {
                    params[p.name] = el.value;
                }
            }
        });

        payload.params = params;

        // Collect value for write
        if (action === 'write') {
            const valEl = container.querySelector('[name="__value__"]');
            if (valEl) {
                try {
                    payload.value = JSON.parse(valEl.value);
                } catch (e) {
                    showResult({ error: 'Invalid JSON in value field: ' + e.message }, true);
                    return;
                }
            }
        }

        // For describe, put entity from params
        if (action === 'describe') {
            const entityEl = container.querySelector('[name="entity"]');
            if (entityEl) payload.entity = entityEl.value;
        }

        showResult('Executing...', false, true);

        try {
            const resp = await fetch(API + '/databases/' + db.name + '/execute', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            const data = await resp.json();
            showResult(data, !resp.ok);
        } catch (e) {
            showResult({ error: 'Network error: ' + e.message }, true);
        }
    }

    function showResult(data, isError, isLoading) {
        resultArea.classList.remove('hidden');
        if (isLoading) {
            resultContent.innerHTML = '<span class="loading">' + data + '</span>';
            return;
        }

        // If it's an array of objects, try to render as table
        if (Array.isArray(data) && data.length > 0 && typeof data[0] === 'object') {
            resultContent.innerHTML = '';
            resultContent.appendChild(buildTable(data));
        } else {
            resultContent.textContent = JSON.stringify(data, null, 2);
        }

        if (isError) {
            resultContent.style.color = '#e74c3c';
        } else {
            resultContent.style.color = '#ecf0f1';
        }
    }

    function buildTable(rows) {
        const table = document.createElement('table');
        table.className = 'result-table';

        // Headers
        const keys = Object.keys(rows[0]);
        const thead = document.createElement('thead');
        const hrow = document.createElement('tr');
        keys.forEach(k => {
            const th = document.createElement('th');
            th.textContent = k;
            hrow.appendChild(th);
        });
        thead.appendChild(hrow);
        table.appendChild(thead);

        // Rows
        const tbody = document.createElement('tbody');
        rows.forEach(row => {
            const tr = document.createElement('tr');
            keys.forEach(k => {
                const td = document.createElement('td');
                const val = row[k];
                td.textContent = (typeof val === 'object' && val !== null) ? JSON.stringify(val) : String(val != null ? val : '');
                tr.appendChild(td);
            });
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        return table;
    }
})();
