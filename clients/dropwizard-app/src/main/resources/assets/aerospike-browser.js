// Aerospike Browser Component
(function() {
    'use strict';

    window.AerospikeDbBrowser = {
        currentNamespace: null,
        
        render: function(container) {
            container.innerHTML = `
                <div id="aerospike-browser">
                    <div class="aerospike-toolbar">
                        <button id="aerospike-refresh-btn" class="aerospike-btn">🔄 Refresh</button>
                    </div>
                    
                    <div class="aerospike-tabs">
                        <button class="aerospike-tab active" data-tab="overview">📊 Overview</button>
                        <button class="aerospike-tab" data-tab="namespaces">🗄️ Namespaces</button>
                        <button class="aerospike-tab" data-tab="sets">📋 Sets</button>
                        <button class="aerospike-tab" data-tab="indices">🔍 Indices</button>
                        <button class="aerospike-tab" data-tab="keys">🔑 Keys</button>
                    </div>
                    
                    <div id="aerospike-content" class="aerospike-content"></div>
                </div>
            `;
            
            this.attachEventListeners();
            this.loadData();
        },
        
        attachEventListeners: function() {
            document.getElementById('aerospike-refresh-btn').addEventListener('click', () => this.loadData());
            
            document.querySelectorAll('.aerospike-tab').forEach(tab => {
                tab.addEventListener('click', (e) => {
                    document.querySelectorAll('.aerospike-tab').forEach(t => t.classList.remove('active'));
                    e.target.classList.add('active');
                    this.showTab(e.target.dataset.tab);
                });
            });
        },
        
        async loadData(namespace, targetTab) {
            try {
                const params = namespace ? { namespace: namespace } : {};
                const response = await fetch('/api/databases/aerospike/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'browse',
                        params: params
                    })
                });
                
                if (!response.ok) throw new Error('Failed to load data');
                
                this.data = await response.json();
                this.currentNamespace = this.data.currentNamespace;
                this.showTab(targetTab || 'overview');
            } catch (e) {
                this.showError('Error loading data: ' + e.message);
            }
        },
        
        showTab: function(tab) {
            const content = document.getElementById('aerospike-content');
            
            switch(tab) {
                case 'overview':
                    this.renderOverview(content);
                    break;
                case 'namespaces':
                    this.renderNamespaces(content);
                    break;
                case 'sets':
                    this.renderSets(content);
                    break;
                case 'indices':
                    this.renderIndices(content);
                    break;
                case 'keys':
                    this.renderKeys(content);
                    break;
            }
        },
        
        renderOverview: function(container) {
            if (!this.data) return;
            
            const cluster = this.data.clusterInfo || {};
            const namespaces = this.data.namespaces || [];
            const sets = this.data.sets || [];
            const indices = this.data.indices || [];
            
            container.innerHTML = `
                <div class="aerospike-section">
                    <h3>🖥️ Cluster Information</h3>
                    <div class="aerospike-info-grid">
                        <div class="aerospike-info-card">
                            <div class="label">Build Version</div>
                            <div class="value">${cluster.build || 'N/A'}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Cluster Name</div>
                            <div class="value">${cluster.clusterName || 'N/A'}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Nodes</div>
                            <div class="value">${cluster.nodes || 0}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Total Namespaces</div>
                            <div class="value">${this.data.totalNamespaces || 0}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Total Sets</div>
                            <div class="value">${this.data.totalSets || 0}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Total Indices</div>
                            <div class="value">${this.data.totalIndices || 0}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Total Records</div>
                            <div class="value">${this.formatNumber(this.data.totalRecords)}</div>
                        </div>
                        <div class="aerospike-info-card">
                            <div class="label">Total Memory</div>
                            <div class="value">${this.formatBytes(this.data.totalMemory)}</div>
                        </div>
                    </div>
                </div>
                
                <div class="aerospike-section">
                    <h3>🔗 Cluster Nodes</h3>
                    <div class="aerospike-table-wrapper">
                        <table class="aerospike-grid">
                            <thead>
                                <tr>
                                    <th>Node Name</th>
                                    <th>Host</th>
                                    <th>Status</th>
                                </tr>
                            </thead>
                            <tbody>
                                ${(cluster.nodeList || []).map(node => `
                                    <tr>
                                        <td><strong>${node.name}</strong></td>
                                        <td>${node.host}</td>
                                        <td><span class="${node.active ? 'status-active' : 'status-inactive'}">${node.active ? '✓ Active' : '✗ Inactive'}</span></td>
                                    </tr>
                                `).join('')}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="aerospike-section">
                    <h3>📊 Current Namespace: <span class="highlight">${this.currentNamespace}</span></h3>
                    <div class="aerospike-stats">
                        <div class="stat-item">
                            <span class="stat-label">Sets:</span>
                            <span class="stat-value">${sets.length}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Indices:</span>
                            <span class="stat-value">${indices.length}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Total Records:</span>
                            <span class="stat-value">${this.formatNumber(this.data.totalRecords)}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Total Memory:</span>
                            <span class="stat-value">${this.formatBytes(this.data.totalMemory)}</span>
                        </div>
                    </div>
                </div>
            `;
        },
        
        renderNamespaces: function(container) {
            if (!this.data) return;
            
            const namespaces = this.data.namespaces || [];
            
            container.innerHTML = `
                <div class="aerospike-section">
                    <h3>🗄️ All Namespaces (${namespaces.length})</h3>
                    <div class="aerospike-table-wrapper">
                        <table class="aerospike-grid">
                            <thead>
                                <tr>
                                    <th>Namespace</th>
                                    <th>Objects</th>
                                    <th>Tombstones</th>
                                    <th>Replication Factor</th>
                                    <th>Memory Size</th>
                                    <th>Available Bins</th>
                                    <th>Actions</th>
                                </tr>
                            </thead>
                            <tbody>
                                ${namespaces.map(ns => `
                                    <tr>
                                        <td><strong>${ns.name}</strong></td>
                                        <td>${this.formatNumber(ns.objects)}</td>
                                        <td>${this.formatNumber(ns.tombstones)}</td>
                                        <td>${ns['replication-factor'] || 'N/A'}</td>
                                        <td>${this.formatBytes(ns['memory-size'])}</td>
                                        <td>${ns.available_bin_names || 'N/A'}</td>
                                        <td>
                                            <button class="aerospike-mini-btn" onclick="AerospikeDbBrowser.switchNamespace('${ns.name}')">
                                                📂 View Sets
                                            </button>
                                        </td>
                                    </tr>
                                `).join('')}
                            </tbody>
                        </table>
                    </div>
                </div>
            `;
        },
        
        renderSets: function(container) {
            if (!this.data) return;
            
            const sets = this.data.sets || [];
            
            container.innerHTML = `
                <div class="aerospike-section">
                    <h3>📋 Sets in Namespace: <span class="highlight">${this.currentNamespace}</span> (${sets.length})</h3>
                    ${sets.length === 0 ? '<p style="text-align:center;color:#999;padding:20px;">No sets in this namespace</p>' : `
                        <div class="aerospike-table-wrapper">
                            <table class="aerospike-grid">
                                <thead>
                                    <tr>
                                        <th>Set Name</th>
                                        <th>Objects (Records)</th>
                                        <th>Tombstones</th>
                                        <th>Memory (Data)</th>
                                        <th>Stop Writes Count</th>
                                        <th>Eviction</th>
                                        <th>XDR Enabled</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ${sets.map(set => `
                                        <tr>
                                            <td>
                                                <strong>
                                                    <a href="#" class="aerospike-set-link" onclick="AerospikeDbBrowser.viewSetKeys('${set.name}'); return false;">
                                                        ${set.name}
                                                    </a>
                                                </strong>
                                            </td>
                                            <td>${this.formatNumber(set.objects)}</td>
                                            <td>${this.formatNumber(set.tombstones)}</td>
                                            <td>${this.formatBytes(set.memory_data_bytes)}</td>
                                            <td>${set['stop-writes-count'] || '0'}</td>
                                            <td>${set['disable-eviction'] === 'true' ? '✗ Disabled' : '✓ Enabled'}</td>
                                            <td>${set['set-enable-xdr'] === 'true' ? '✓ Yes' : '✗ No'}</td>
                                        </tr>
                                    `).join('')}
                                </tbody>
                            </table>
                        </div>
                    `}
                </div>
            `;
        },
        
        renderIndices: function(container) {
            if (!this.data) return;
            
            const indices = this.data.indices || [];
            
            container.innerHTML = `
                <div class="aerospike-section">
                    <h3>🔍 Secondary Indices in Namespace: <span class="highlight">${this.currentNamespace}</span> (${indices.length})</h3>
                    ${indices.length === 0 ? '<p style="text-align:center;color:#999;padding:20px;">No secondary indices in this namespace</p>' : `
                        <div class="aerospike-table-wrapper">
                            <table class="aerospike-grid">
                                <thead>
                                    <tr>
                                        <th>Index Name</th>
                                        <th>Set</th>
                                        <th>Bin</th>
                                        <th>Type</th>
                                        <th>Index Type</th>
                                        <th>State</th>
                                        <th>Keys</th>
                                        <th>Entries</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ${indices.map(idx => `
                                        <tr>
                                            <td><strong>${idx.indexname}</strong></td>
                                            <td>${idx.set || 'N/A'}</td>
                                            <td>${idx.bin}</td>
                                            <td>${idx.type}</td>
                                            <td>${idx.indextype}</td>
                                            <td><span class="${idx.state === 'RW' ? 'status-active' : 'status-inactive'}">${idx.state}</span></td>
                                            <td>${this.formatNumber(idx.keys)}</td>
                                            <td>${this.formatNumber(idx.entries)}</td>
                                        </tr>
                                    `).join('')}
                                </tbody>
                            </table>
                        </div>
                    `}
                </div>
            `;
        },
        
        async switchNamespace(namespace) {
            // Update active tab
            document.querySelectorAll('.aerospike-tab').forEach(t => t.classList.remove('active'));
            document.querySelector('.aerospike-tab[data-tab="sets"]').classList.add('active');
            
            // Reload data with new namespace, show sets tab
            await this.loadData(namespace, 'sets');
        },
        
        viewSetKeys: function(setName) {
            // Update active tab
            document.querySelectorAll('.aerospike-tab').forEach(t => t.classList.remove('active'));
            document.querySelector('.aerospike-tab[data-tab="keys"]').classList.add('active');
            
            // Switch to Keys tab with pre-selected set
            this.showTab('keys');
            
            // Wait for DOM to render, then set the selected set and auto-scan
            setTimeout(() => {
                const setSelect = document.getElementById('aerospike-scan-set');
                if (setSelect) {
                    setSelect.value = setName;
                    // Auto-trigger scan
                    this.scanKeys();
                }
            }, 100);
        },
        
        renderKeys: function(container) {
            if (!this.data) return;
            
            const sets = this.data.sets || [];
            
            container.innerHTML = `
                <div class="aerospike-section">
                    <h3>🔑 Browse Keys by Set</h3>
                    <div class="aerospike-key-browser">
                        <div class="aerospike-form">
                            <label>Namespace:</label>
                            <input type="text" id="aerospike-scan-namespace" value="${this.currentNamespace}" readonly />
                            
                            <label>Set:</label>
                            <select id="aerospike-scan-set">
                                ${sets.map(s => `<option value="${s.name}">${s.name}</option>`).join('')}
                            </select>
                            
                            <label>Max Records:</label>
                            <input type="number" id="aerospike-scan-max" value="100" min="1" max="1000" />
                            
                            <button class="aerospike-btn primary" onclick="AerospikeDbBrowser.scanKeys()">🔍 Scan Keys</button>
                        </div>
                        
                        <div id="aerospike-keys-result"></div>
                    </div>
                </div>
            `;
        },
        
        async scanKeys() {
            const namespace = document.getElementById('aerospike-scan-namespace').value;
            const set = document.getElementById('aerospike-scan-set').value;
            const maxRecords = document.getElementById('aerospike-scan-max').value;
            
            const resultDiv = document.getElementById('aerospike-keys-result');
            resultDiv.innerHTML = '<p style="color:#3498db;padding:20px;">Scanning...</p>';
            
            try {
                const response = await fetch('/api/databases/aerospike/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'scanSet',
                        params: {
                            namespace: namespace,
                            set: set,
                            maxRecords: maxRecords
                        }
                    })
                });
                
                if (!response.ok) throw new Error('Scan failed');
                
                const result = await response.json();
                this.renderScanResults(result);
                
            } catch (e) {
                resultDiv.innerHTML = `<p style="color:#e74c3c;padding:20px;">Error: ${e.message}</p>`;
            }
        },
        
        renderScanResults: function(result) {
            const resultDiv = document.getElementById('aerospike-keys-result');
            const records = result.records || [];
            
            if (records.length === 0) {
                resultDiv.innerHTML = '<p style="text-align:center;color:#999;padding:20px;">No records found</p>';
                return;
            }
            
            resultDiv.innerHTML = `
                <h4 style="margin-top:20px;">Found ${records.length} records</h4>
                <div class="aerospike-table-wrapper">
                    <table class="aerospike-grid">
                        <thead>
                            <tr>
                                <th>Key</th>
                                <th>Generation</th>
                                <th>TTL</th>
                                <th>Bins</th>
                                <th>Actions</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${records.map(record => `
                                <tr>
                                    <td><strong>${this.escapeHtml(record.key)}</strong></td>
                                    <td>${record.generation}</td>
                                    <td>${record.ttl >= 0 ? record.ttl + 's' : 'Never expires'}</td>
                                    <td>${Object.keys(record.bins || {}).length} bins</td>
                                    <td>
                                        <button class="aerospike-mini-btn" onclick="AerospikeDbBrowser.viewRecord('${this.escapeHtml(record.key)}')">
                                            👁️ View
                                        </button>
                                    </td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
            `;
        },
        
        async viewRecord(key) {
            const namespace = document.getElementById('aerospike-scan-namespace').value;
            const set = document.getElementById('aerospike-scan-set').value;
            
            try {
                const response = await fetch('/api/databases/aerospike/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'getByKey',
                        params: {
                            namespace: namespace,
                            set: set,
                            key: key
                        }
                    })
                });
                
                if (!response.ok) throw new Error('Failed to get record');
                
                const record = await response.json();
                this.showRecordModal(record);
                
            } catch (e) {
                alert('Error: ' + e.message);
            }
        },
        
        showRecordModal: function(record) {
            // Create modal overlay
            const modal = document.createElement('div');
            modal.className = 'aerospike-modal-overlay';
            
            // Format bins - parse JSON values if they are strings
            let binsHtml = '';
            if (record.found && record.bins) {
                binsHtml = '<h4>Bins:</h4>';
                for (const [binName, binValue] of Object.entries(record.bins)) {
                    let formattedValue = binValue;
                    
                    // Try to parse as JSON if it's a string
                    if (typeof binValue === 'string') {
                        try {
                            const parsed = JSON.parse(binValue);
                            formattedValue = JSON.stringify(parsed, null, 2);
                        } catch (e) {
                            // Not JSON, use as-is
                            formattedValue = binValue;
                        }
                    } else {
                        formattedValue = JSON.stringify(binValue, null, 2);
                    }
                    
                    binsHtml += `
                        <div class="aerospike-bin-container">
                            <div class="aerospike-bin-name">${this.escapeHtml(binName)}</div>
                            <pre class="aerospike-record-data">${this.escapeHtml(formattedValue)}</pre>
                        </div>
                    `;
                }
            }
            
            modal.innerHTML = `
                <div class="aerospike-modal">
                    <div class="aerospike-modal-header">
                        <h3>Record Details: ${this.escapeHtml(record.key)}</h3>
                        <button class="aerospike-modal-close" onclick="this.closest('.aerospike-modal-overlay').remove()">✕</button>
                    </div>
                    <div class="aerospike-modal-body">
                        ${!record.found ? '<p style="color:#e74c3c;">Record not found</p>' : `
                            <div class="aerospike-record-info">
                                <div class="info-row">
                                    <span class="label">Key:</span>
                                    <span class="value">${this.escapeHtml(record.key)}</span>
                                </div>
                                <div class="info-row">
                                    <span class="label">Generation:</span>
                                    <span class="value">${record.generation}</span>
                                </div>
                                <div class="info-row">
                                    <span class="label">TTL:</span>
                                    <span class="value">${record.ttl >= 0 ? record.ttl + ' seconds' : 'Never expires'}</span>
                                </div>
                                <div class="info-row">
                                    <span class="label">Expiration:</span>
                                    <span class="value">${record.expiration}</span>
                                </div>
                            </div>
                            ${binsHtml}
                        `}
                    </div>
                </div>
            `;
            
            document.body.appendChild(modal);
            
            // Close on overlay click
            modal.addEventListener('click', (e) => {
                if (e.target === modal) {
                    modal.remove();
                }
            });
        },
        
        escapeHtml: function(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        },
        
        formatBytes: function(bytes) {
            if (!bytes || bytes === 0) return '0 B';
            const num = parseInt(bytes);
            if (isNaN(num)) return 'N/A';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(num) / Math.log(k));
            return Math.round(num / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
        },
        
        formatNumber: function(num) {
            if (!num && num !== 0) return 'N/A';
            const n = parseInt(num);
            if (isNaN(n)) return 'N/A';
            return n.toLocaleString();
        },
        
        showError: function(message) {
            const content = document.getElementById('aerospike-content');
            content.innerHTML = `<p style="color:#e74c3c;padding:20px;text-align:center;">${message}</p>`;
        }
    };
})();
