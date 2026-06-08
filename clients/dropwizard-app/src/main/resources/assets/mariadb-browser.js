// MariaDB Browser Component
(function() {
    'use strict';

    window.MariaDbBrowser = {
        currentDatabase: null,
        
        render: function(container) {
            container.innerHTML = `
                <div id="mariadb-browser">
                    <div class="mariadb-toolbar">
                        <button id="mariadb-refresh-btn" class="mariadb-btn">🔄 Refresh</button>
                        <button id="mariadb-query-btn" class="mariadb-btn primary">📝 Run Query</button>
                    </div>
                    
                    <div class="mariadb-tabs">
                        <button class="mariadb-tab active" data-tab="overview">📊 Overview</button>
                        <button class="mariadb-tab" data-tab="databases">🗄️ Databases</button>
                        <button class="mariadb-tab" data-tab="tables">📋 Tables</button>
                        <button class="mariadb-tab" data-tab="users">👥 Users</button>
                        <button class="mariadb-tab" data-tab="query">⚡ Query</button>
                    </div>
                    
                    <div id="mariadb-content" class="mariadb-content"></div>
                </div>
            `;
            
            this.attachEventListeners();
            this.loadData();
        },
        
        attachEventListeners: function() {
            document.getElementById('mariadb-refresh-btn').addEventListener('click', () => this.loadData());
            document.getElementById('mariadb-query-btn').addEventListener('click', () => this.showTab('query'));
            
            document.querySelectorAll('.mariadb-tab').forEach(tab => {
                tab.addEventListener('click', (e) => {
                    document.querySelectorAll('.mariadb-tab').forEach(t => t.classList.remove('active'));
                    e.target.classList.add('active');
                    this.showTab(e.target.dataset.tab);
                });
            });
        },
        
        async loadData() {
            try {
                const response = await fetch('/api/databases/mariadb/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'browse',
                        params: {}
                    })
                });
                
                if (!response.ok) throw new Error('Failed to load data');
                
                this.data = await response.json();
                this.showTab('overview');
            } catch (e) {
                this.showError('Error loading data: ' + e.message);
            }
        },
        
        showTab: function(tab) {
            const content = document.getElementById('mariadb-content');
            
            switch(tab) {
                case 'overview':
                    this.renderOverview(content);
                    break;
                case 'databases':
                    this.renderDatabases(content);
                    break;
                case 'tables':
                    this.renderTables(content);
                    break;
                case 'users':
                    this.renderUsers(content);
                    break;
                case 'query':
                    this.renderQuery(content);
                    break;
            }
        },
        
        renderOverview: function(container) {
            if (!this.data) return;
            
            const serverInfo = this.data.serverInfo || {};
            const databases = this.data.databases || [];
            const tables = this.data.tables || [];
            const users = this.data.users || [];
            
            container.innerHTML = `
                <div class="mariadb-section">
                    <h3>🖥️ Server Information</h3>
                    <div class="mariadb-info-grid">
                        <div class="mariadb-info-card">
                            <div class="label">Version</div>
                            <div class="value">${serverInfo.version || 'N/A'}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">Hostname</div>
                            <div class="value">${serverInfo.hostname || 'N/A'}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">Port</div>
                            <div class="value">${serverInfo.port || 'N/A'}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">GTID Enabled</div>
                            <div class="value ${serverInfo.gtid_enabled ? 'success' : 'warning'}">
                                ${serverInfo.gtid_enabled ? '✓ Yes' : '✗ No'}
                            </div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">GTID Domain ID</div>
                            <div class="value">${serverInfo.gtid_domain_id !== undefined ? serverInfo.gtid_domain_id : 'N/A'}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">Total Databases</div>
                            <div class="value">${databases.length}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">Total Tables</div>
                            <div class="value">${tables.length}</div>
                        </div>
                        <div class="mariadb-info-card">
                            <div class="label">Total Users</div>
                            <div class="value">${users.length}</div>
                        </div>
                    </div>
                </div>
                
                <div class="mariadb-section">
                    <h3>📊 Quick Stats</h3>
                    <div class="mariadb-stats">
                        <div class="stat-item">
                            <span class="stat-label">Current Database:</span>
                            <span class="stat-value">${this.data.currentDatabase || 'N/A'}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Tables in Current DB:</span>
                            <span class="stat-value">${tables.length}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Total Rows:</span>
                            <span class="stat-value">${this.formatNumber(tables.reduce((sum, t) => sum + (t.rows || 0), 0))}</span>
                        </div>
                        <div class="stat-item">
                            <span class="stat-label">Total Size:</span>
                            <span class="stat-value">${this.formatBytes(tables.reduce((sum, t) => sum + (t.totalSize || 0), 0))}</span>
                        </div>
                    </div>
                </div>
            `;
        },
        
        renderDatabases: function(container) {
            if (!this.data) return;
            
            const databases = this.data.databases || [];
            
            container.innerHTML = `
                <div class="mariadb-section">
                    <h3>🗄️ All Databases (${databases.length})</h3>
                    <div class="mariadb-table-wrapper">
                        <table class="mariadb-grid">
                            <thead>
                                <tr>
                                    <th>Database Name</th>
                                    <th>Character Set</th>
                                    <th>Collation</th>
                                    <th>Actions</th>
                                </tr>
                            </thead>
                            <tbody>
                                ${databases.map(db => `
                                    <tr>
                                        <td><strong>${db.name}</strong></td>
                                        <td>${db.charset || 'N/A'}</td>
                                        <td>${db.collation || 'N/A'}</td>
                                        <td>
                                            <button class="mariadb-mini-btn" onclick="MariaDbBrowser.switchDatabase('${db.name}')">
                                                📂 View Tables
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
        
        renderTables: function(container) {
            if (!this.data) return;
            
            const tables = this.data.tables || [];
            const currentDb = this.data.currentDatabase;
            
            container.innerHTML = `
                <div class="mariadb-section">
                    <h3>📋 Tables in Database: <span class="highlight">${currentDb}</span> (${tables.length})</h3>
                    ${tables.length === 0 ? '<p style="text-align:center;color:#999;padding:20px;">No tables in this database</p>' : `
                        <div class="mariadb-table-wrapper">
                            <table class="mariadb-grid">
                                <thead>
                                    <tr>
                                        <th>Table Name</th>
                                        <th>Type</th>
                                        <th>Engine</th>
                                        <th>Rows</th>
                                        <th>Data Size</th>
                                        <th>Index Size</th>
                                        <th>Total Size</th>
                                        <th>Created</th>
                                        <th>Updated</th>
                                        <th>Actions</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ${tables.map(table => `
                                        <tr>
                                            <td><strong>${table.name}</strong></td>
                                            <td>${table.type || 'N/A'}</td>
                                            <td>${table.engine || 'N/A'}</td>
                                            <td>${this.formatNumber(table.rows)}</td>
                                            <td>${this.formatBytes(table.dataSize)}</td>
                                            <td>${this.formatBytes(table.indexSize)}</td>
                                            <td><strong>${this.formatBytes(table.totalSize)}</strong></td>
                                            <td>${this.formatDate(table.created)}</td>
                                            <td>${this.formatDate(table.updated)}</td>
                                            <td>
                                                <button class="mariadb-mini-btn" onclick="MariaDbBrowser.describeTable('${table.name}')">
                                                    📝 Describe
                                                </button>
                                                <button class="mariadb-mini-btn" onclick="MariaDbBrowser.selectTable('${table.name}')">
                                                    🔍 Browse
                                                </button>
                                            </td>
                                        </tr>
                                    `).join('')}
                                </tbody>
                            </table>
                        </div>
                    `}
                </div>
            `;
        },
        
        renderUsers: function(container) {
            if (!this.data) return;
            
            const users = this.data.users || [];
            
            container.innerHTML = `
                <div class="mariadb-section">
                    <h3>👥 Database Users (${users.length})</h3>
                    <div class="mariadb-table-wrapper">
                        <table class="mariadb-grid">
                            <thead>
                                <tr>
                                    <th>User</th>
                                    <th>Host</th>
                                    <th>SELECT</th>
                                    <th>INSERT</th>
                                    <th>UPDATE</th>
                                    <th>DELETE</th>
                                    <th>CREATE</th>
                                    <th>DROP</th>
                                    <th>GRANT</th>
                                    <th>SUPER</th>
                                    <th>Actions</th>
                                </tr>
                            </thead>
                            <tbody>
                                ${users.map(user => {
                                    const priv = user.privileges || {};
                                    return `
                                        <tr>
                                            <td><strong>${user.username}</strong></td>
                                            <td>${user.host}</td>
                                            <td>${this.renderPriv(priv.SELECT)}</td>
                                            <td>${this.renderPriv(priv.INSERT)}</td>
                                            <td>${this.renderPriv(priv.UPDATE)}</td>
                                            <td>${this.renderPriv(priv.DELETE)}</td>
                                            <td>${this.renderPriv(priv.CREATE)}</td>
                                            <td>${this.renderPriv(priv.DROP)}</td>
                                            <td>${this.renderPriv(priv.GRANT)}</td>
                                            <td>${this.renderPriv(priv.SUPER)}</td>
                                            <td>
                                                <button class="mariadb-mini-btn" onclick="MariaDbBrowser.showGrants('${user.username}', '${user.host}')">
                                                    📜 Show Grants
                                                </button>
                                            </td>
                                        </tr>
                                    `;
                                }).join('')}
                            </tbody>
                        </table>
                    </div>
                </div>
            `;
        },
        
        renderQuery: function(container) {
            container.innerHTML = `
                <div class="mariadb-section">
                    <h3>⚡ Execute SQL Query</h3>
                    <div class="mariadb-query-editor">
                        <textarea id="mariadb-query-input" placeholder="Enter your SQL query here...
Example: SELECT * FROM users LIMIT 10;"></textarea>
                        <div class="mariadb-query-actions">
                            <button class="mariadb-btn primary" onclick="MariaDbBrowser.executeQuery()">▶ Execute</button>
                            <button class="mariadb-btn" onclick="document.getElementById('mariadb-query-input').value=''">🗑 Clear</button>
                        </div>
                    </div>
                    <div id="mariadb-query-result" class="mariadb-query-result"></div>
                </div>
            `;
        },
        
        async executeQuery() {
            const query = document.getElementById('mariadb-query-input').value.trim();
            if (!query) {
                alert('Please enter a query');
                return;
            }
            
            const resultDiv = document.getElementById('mariadb-query-result');
            resultDiv.innerHTML = '<p style="color:#3498db;">Executing...</p>';
            
            try {
                const response = await fetch('/api/databases/mariadb/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'query',
                        query: query
                    })
                });
                
                if (!response.ok) throw new Error('Query failed');
                
                const results = await response.json();
                
                if (results.length === 0) {
                    resultDiv.innerHTML = '<p style="color:#999;">No results returned</p>';
                    return;
                }
                
                // Check if it's an update result
                if (results[0]._updateCount !== undefined) {
                    resultDiv.innerHTML = `<p style="color:#27ae60;">✓ Query OK, ${results[0]._updateCount} rows affected</p>`;
                    return;
                }
                
                // Render as table
                const keys = Object.keys(results[0]);
                resultDiv.innerHTML = `
                    <p style="color:#27ae60;">✓ ${results.length} rows returned</p>
                    <div class="mariadb-table-wrapper">
                        <table class="mariadb-grid">
                            <thead>
                                <tr>${keys.map(k => `<th>${k}</th>`).join('')}</tr>
                            </thead>
                            <tbody>
                                ${results.map(row => `
                                    <tr>${keys.map(k => `<td>${this.escapeHtml(String(row[k] || ''))}</td>`).join('')}</tr>
                                `).join('')}
                            </tbody>
                        </table>
                    </div>
                `;
            } catch (e) {
                resultDiv.innerHTML = `<p style="color:#e74c3c;">✗ Error: ${e.message}</p>`;
            }
        },
        
        async switchDatabase(dbName) {
            // Reload data with new database
            try {
                const response = await fetch('/api/databases/mariadb/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'browse',
                        params: { database: dbName }
                    })
                });
                
                if (!response.ok) throw new Error('Failed to switch database');
                
                this.data = await response.json();
                
                // Update active tab
                document.querySelectorAll('.mariadb-tab').forEach(t => t.classList.remove('active'));
                document.querySelector('.mariadb-tab[data-tab="tables"]').classList.add('active');
                
                this.showTab('tables');
            } catch (e) {
                alert('Error switching database: ' + e.message);
            }
        },
        
        async describeTable(tableName) {
            // Update active tab
            document.querySelectorAll('.mariadb-tab').forEach(t => t.classList.remove('active'));
            document.querySelector('.mariadb-tab[data-tab="query"]').classList.add('active');
            
            // Switch to query tab and set query
            this.showTab('query');
            
            // Wait for DOM to update, then set query and execute
            setTimeout(() => {
                const query = `DESCRIBE ${tableName}`;
                document.getElementById('mariadb-query-input').value = query;
                this.executeQuery();
            }, 100);
        },
        
        async selectTable(tableName) {
            // Update active tab
            document.querySelectorAll('.mariadb-tab').forEach(t => t.classList.remove('active'));
            document.querySelector('.mariadb-tab[data-tab="query"]').classList.add('active');
            
            // Switch to query tab and set query
            this.showTab('query');
            
            // Wait for DOM to update, then set query and execute
            setTimeout(() => {
                const query = `SELECT * FROM ${tableName} LIMIT 100`;
                document.getElementById('mariadb-query-input').value = query;
                this.executeQuery();
            }, 100);
        },
        
        async showGrants(username, host) {
            // Update active tab
            document.querySelectorAll('.mariadb-tab').forEach(t => t.classList.remove('active'));
            document.querySelector('.mariadb-tab[data-tab="query"]').classList.add('active');
            
            // Switch to query tab and set query
            this.showTab('query');
            
            // Wait for DOM to update, then set query and execute
            setTimeout(() => {
                const query = `SHOW GRANTS FOR '${username}'@'${host}'`;
                document.getElementById('mariadb-query-input').value = query;
                this.executeQuery();
            }, 100);
        },
        
        renderPriv: function(has) {
            return has ? '<span class="priv-yes">✓</span>' : '<span class="priv-no">✗</span>';
        },
        
        formatBytes: function(bytes) {
            if (!bytes || bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
        },
        
        formatNumber: function(num) {
            if (!num && num !== 0) return 'N/A';
            return num.toLocaleString();
        },
        
        formatDate: function(date) {
            if (!date) return 'N/A';
            return new Date(date).toLocaleString();
        },
        
        escapeHtml: function(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        },
        
        showError: function(message) {
            const content = document.getElementById('mariadb-content');
            content.innerHTML = `<p style="color:#e74c3c;padding:20px;text-align:center;">${message}</p>`;
        }
    };
})();
