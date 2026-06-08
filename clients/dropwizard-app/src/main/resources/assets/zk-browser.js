// ZooKeeper Browser Component
(function() {
    'use strict';

    window.ZkBrowser = {
        currentPath: '/',
        
        render: function(container) {
            container.innerHTML = `
                <div id="zk-browser">
                    <div class="zk-path-bar">
                        <button id="zk-up-btn" class="zk-nav-btn" title="Go up one level">
                            ⬆ Up
                        </button>
                        <div id="zk-breadcrumbs" class="zk-breadcrumbs"></div>
                        <button id="zk-refresh-btn" class="zk-nav-btn" title="Refresh">
                            🔄 Refresh
                        </button>
                    </div>
                    
                    <div class="zk-current-node">
                        <h4>Current Node: <span id="zk-current-path">/</span></h4>
                        <div class="zk-node-data">
                            <label>Data:</label>
                            <textarea id="zk-current-data" readonly></textarea>
                        </div>
                        <div class="zk-node-metadata" id="zk-node-metadata"></div>
                    </div>
                    
                    <div class="zk-children-section">
                        <h4>Children (<span id="zk-children-count">0</span>)</h4>
                        <div class="zk-grid-container">
                            <table id="zk-children-grid" class="zk-grid">
                                <thead>
                                    <tr>
                                        <th>Name</th>
                                        <th>Data Size</th>
                                        <th>Children</th>
                                        <th>Version</th>
                                        <th>Modified</th>
                                        <th>Type</th>
                                        <th>Preview</th>
                                        <th>Actions</th>
                                    </tr>
                                </thead>
                                <tbody id="zk-grid-body">
                                </tbody>
                            </table>
                        </div>
                    </div>
                    
                    <div class="zk-actions">
                        <button id="zk-create-btn" class="zk-action-btn">+ Create Child</button>
                        <button id="zk-edit-btn" class="zk-action-btn">✏ Edit Current</button>
                        <button id="zk-delete-btn" class="zk-action-btn danger">🗑 Delete Current</button>
                    </div>
                </div>
            `;
            
            this.attachEventListeners();
            this.loadPath('/');
        },
        
        attachEventListeners: function() {
            document.getElementById('zk-up-btn').addEventListener('click', () => this.goUp());
            document.getElementById('zk-refresh-btn').addEventListener('click', () => this.loadPath(this.currentPath));
            document.getElementById('zk-create-btn').addEventListener('click', () => this.createChild());
            document.getElementById('zk-edit-btn').addEventListener('click', () => this.editCurrent());
            document.getElementById('zk-delete-btn').addEventListener('click', () => this.deleteCurrent());
        },
        
        async loadPath(path) {
            this.currentPath = path;
            document.getElementById('zk-current-path').textContent = path;
            
            try {
                const response = await fetch('/api/databases/zk/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'browse',
                        params: { path: path }
                    })
                });
                
                if (!response.ok) {
                    throw new Error('Failed to browse: ' + response.statusText);
                }
                
                const data = await response.json();
                this.renderData(data);
            } catch (e) {
                this.showError('Error loading path: ' + e.message);
            }
        },
        
        renderData: function(data) {
            // Update current node data
            document.getElementById('zk-current-data').value = data.currentData || '';
            
            // Update metadata
            const metadataDiv = document.getElementById('zk-node-metadata');
            const stat = data.currentStat || {};
            metadataDiv.innerHTML = `
                <div class="zk-metadata-grid">
                    <div><strong>Version:</strong> ${stat.version || 0}</div>
                    <div><strong>Children:</strong> ${stat.numChildren || 0}</div>
                    <div><strong>Data Length:</strong> ${stat.dataLength || 0} bytes</div>
                    <div><strong>Ephemeral:</strong> ${stat.ephemeral ? 'Yes' : 'No'}</div>
                    <div><strong>Created:</strong> ${this.formatTime(stat.ctime)}</div>
                    <div><strong>Modified:</strong> ${this.formatTime(stat.mtime)}</div>
                </div>
            `;
            
            // Update breadcrumbs
            this.renderBreadcrumbs(data.currentPath);
            
            // Update children count
            const children = data.children || [];
            document.getElementById('zk-children-count').textContent = children.length;
            
            // Render children grid
            const tbody = document.getElementById('zk-grid-body');
            tbody.innerHTML = '';
            
            if (children.length === 0) {
                tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;color:#999;">No children</td></tr>';
                return;
            }
            
            children.forEach(child => {
                const row = document.createElement('tr');
                row.className = 'zk-grid-row';
                row.innerHTML = `
                    <td class="zk-name-cell">
                        <a href="#" class="zk-name-link" data-path="${child.path}">${child.name}</a>
                    </td>
                    <td>${this.formatBytes(child.dataLength)}</td>
                    <td>${child.numChildren || 0}</td>
                    <td>${child.version || 0}</td>
                    <td>${this.formatTime(child.mtime)}</td>
                    <td>${child.ephemeral ? '<span class="zk-ephemeral">Ephemeral</span>' : '<span class="zk-persistent">Persistent</span>'}</td>
                    <td class="zk-preview-cell">${this.escapeHtml(child.dataPreview || '')}</td>
                    <td>
                        <button class="zk-mini-btn" data-action="view" data-path="${child.path}" title="View">👁</button>
                        <button class="zk-mini-btn" data-action="edit" data-path="${child.path}" title="Edit">✏</button>
                        <button class="zk-mini-btn danger" data-action="delete" data-path="${child.path}" title="Delete">🗑</button>
                    </td>
                `;
                tbody.appendChild(row);
            });
            
            // Attach click handlers
            tbody.querySelectorAll('.zk-name-link').forEach(link => {
                link.addEventListener('click', (e) => {
                    e.preventDefault();
                    this.loadPath(e.target.dataset.path);
                });
            });
            
            tbody.querySelectorAll('.zk-mini-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    const action = e.target.dataset.action;
                    const path = e.target.dataset.path;
                    if (action === 'view') this.loadPath(path);
                    else if (action === 'edit') this.editNode(path);
                    else if (action === 'delete') this.deleteNode(path);
                });
            });
        },
        
        renderBreadcrumbs: function(path) {
            const breadcrumbsDiv = document.getElementById('zk-breadcrumbs');
            const parts = path === '/' ? ['/'] : path.split('/').filter(p => p);
            
            let html = '<a href="#" class="zk-breadcrumb" data-path="/">Root</a>';
            let currentPath = '';
            
            parts.forEach((part, index) => {
                if (part === '' && index === 0) return; // Skip empty root
                currentPath += '/' + part;
                html += ` <span class="zk-breadcrumb-sep">/</span> <a href="#" class="zk-breadcrumb" data-path="${currentPath}">${part}</a>`;
            });
            
            breadcrumbsDiv.innerHTML = html;
            
            // Attach click handlers
            breadcrumbsDiv.querySelectorAll('.zk-breadcrumb').forEach(link => {
                link.addEventListener('click', (e) => {
                    e.preventDefault();
                    this.loadPath(e.target.dataset.path);
                });
            });
        },
        
        goUp: function() {
            if (this.currentPath === '/') {
                alert('Already at root');
                return;
            }
            const parentPath = this.currentPath.substring(0, Math.max(this.currentPath.lastIndexOf('/'), 1));
            this.loadPath(parentPath || '/');
        },
        
        async createChild() {
            const name = prompt('Enter child node name:');
            if (!name) return;
            
            const data = prompt('Enter node data (optional):', '');
            const childPath = this.currentPath === '/' ? '/' + name : this.currentPath + '/' + name;
            
            try {
                await fetch('/api/databases/zk/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'write',
                        params: { path: childPath },
                        value: { data: data || '' }
                    })
                });
                alert('Created: ' + childPath);
                this.loadPath(this.currentPath);
            } catch (e) {
                alert('Error creating node: ' + e.message);
            }
        },
        
        async editCurrent() {
            const currentData = document.getElementById('zk-current-data').value;
            const newData = prompt('Edit node data:', currentData);
            if (newData === null) return;
            
            try {
                await fetch('/api/databases/zk/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'write',
                        params: { path: this.currentPath },
                        value: { data: newData }
                    })
                });
                alert('Updated: ' + this.currentPath);
                this.loadPath(this.currentPath);
            } catch (e) {
                alert('Error updating node: ' + e.message);
            }
        },
        
        async editNode(path) {
            this.loadPath(path);
        },
        
        async deleteCurrent() {
            if (this.currentPath === '/') {
                alert('Cannot delete root node');
                return;
            }
            
            if (!confirm('Delete ' + this.currentPath + '?')) return;
            
            try {
                await fetch('/api/databases/zk/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'delete',
                        params: { path: this.currentPath }
                    })
                });
                alert('Deleted: ' + this.currentPath);
                this.goUp();
            } catch (e) {
                alert('Error deleting node: ' + e.message);
            }
        },
        
        async deleteNode(path) {
            if (!confirm('Delete ' + path + '?')) return;
            
            try {
                await fetch('/api/databases/zk/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        action: 'delete',
                        params: { path: path }
                    })
                });
                alert('Deleted: ' + path);
                this.loadPath(this.currentPath);
            } catch (e) {
                alert('Error deleting node: ' + e.message);
            }
        },
        
        formatBytes: function(bytes) {
            if (bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
        },
        
        formatTime: function(timestamp) {
            if (!timestamp) return '-';
            const date = new Date(timestamp);
            return date.toLocaleString();
        },
        
        escapeHtml: function(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        },
        
        showError: function(message) {
            alert(message);
        }
    };
})();
