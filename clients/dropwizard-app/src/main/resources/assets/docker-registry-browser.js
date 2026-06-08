// Docker Registry Browser Component
(function() {
    'use strict';

    window.DockerRegistryBrowser = {
        
        render: function(container) {
            container.innerHTML = `
                <div id="docker-registry-browser">
                    <div class="docker-registry-toolbar">
                        <button id="docker-registry-refresh-btn" class="docker-registry-btn">🔄 Refresh</button>
                    </div>
                    
                    <div class="docker-registry-tabs">
                        <button class="docker-registry-tab active" data-tab="overview">📊 Overview</button>
                        <button class="docker-registry-tab" data-tab="images">🐳 Images</button>
                    </div>
                    
                    <div id="docker-registry-content" class="docker-registry-content"></div>
                </div>
            `;
            
            this.attachEventListeners();
            this.loadData();
        },
        
        attachEventListeners: function() {
            document.getElementById('docker-registry-refresh-btn').addEventListener('click', () => this.loadData());
            
            document.querySelectorAll('.docker-registry-tab').forEach(tab => {
                tab.addEventListener('click', (e) => {
                    document.querySelectorAll('.docker-registry-tab').forEach(t => t.classList.remove('active'));
                    e.target.classList.add('active');
                    this.showTab(e.target.dataset.tab);
                });
            });
        },
        
        async loadData() {
            try {
                const response = await fetch('/api/databases/docker-registry/execute', {
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
            const content = document.getElementById('docker-registry-content');
            
            switch(tab) {
                case 'overview':
                    this.renderOverview(content);
                    break;
                case 'images':
                    this.renderImages(content);
                    break;
            }
        },
        
        renderOverview: function(container) {
            if (!this.data) return;
            
            const repos = this.data.repositories || [];
            const totalTags = repos.reduce((sum, r) => sum + (r.tagCount || 0), 0);
            const totalSize = repos.reduce((sum, r) => {
                const repoSize = (r.tags || []).reduce((s, t) => s + (t.size || 0), 0);
                return sum + repoSize;
            }, 0);
            
            container.innerHTML = `
                <div class="docker-registry-section">
                    <h3>🐳 Registry Information</h3>
                    <div class="docker-registry-info-grid">
                        <div class="docker-registry-info-card">
                            <div class="label">Registry URL</div>
                            <div class="value">${this.data.registryUrl || 'N/A'}</div>
                        </div>
                        <div class="docker-registry-info-card">
                            <div class="label">Host</div>
                            <div class="value">${this.data.host || 'N/A'}</div>
                        </div>
                        <div class="docker-registry-info-card">
                            <div class="label">Port</div>
                            <div class="value">${this.data.port || 'N/A'}</div>
                        </div>
                        <div class="docker-registry-info-card">
                            <div class="label">Total Repositories</div>
                            <div class="value">${this.data.totalRepositories || 0}</div>
                        </div>
                        <div class="docker-registry-info-card">
                            <div class="label">Total Tags</div>
                            <div class="value">${totalTags}</div>
                        </div>
                        <div class="docker-registry-info-card">
                            <div class="label">Total Size</div>
                            <div class="value">${this.formatBytes(totalSize)}</div>
                        </div>
                    </div>
                </div>
                
                <div class="docker-registry-section">
                    <h3>📦 Repositories Summary</h3>
                    <div class="docker-registry-stats">
                        ${repos.length === 0 ? '<p style="text-align:center;color:#999;padding:20px;">No repositories found</p>' : repos.map(repo => `
                            <div class="docker-registry-repo-card">
                                <div class="repo-name">🐳 ${repo.name}</div>
                                <div class="repo-stats">
                                    <span class="stat-badge">${repo.tagCount || 0} tags</span>
                                    <span class="stat-badge">${this.formatBytes((repo.tags || []).reduce((s, t) => s + (t.size || 0), 0))}</span>
                                </div>
                            </div>
                        `).join('')}
                    </div>
                </div>
            `;
        },
        
        renderImages: function(container) {
            if (!this.data) return;
            
            const repos = this.data.repositories || [];
            
            container.innerHTML = `
                <div class="docker-registry-section">
                    <h3>🐳 Docker Images (${repos.length})</h3>
                    ${repos.length === 0 ? '<p style="text-align:center;color:#999;padding:20px;">No images in this registry</p>' : 
                        repos.map(repo => `
                            <div class="docker-registry-image-section">
                                <div class="docker-registry-image-header">
                                    <h4>📦 ${repo.name}</h4>
                                    <span class="tag-count">${repo.tagCount || 0} tags</span>
                                </div>
                                ${repo.error ? `<p style="color:#e74c3c;padding:10px;">Error: ${repo.error}</p>` : ''}
                                ${(repo.tags && repo.tags.length > 0) ? `
                                    <div class="docker-registry-table-wrapper">
                                        <table class="docker-registry-grid">
                                            <thead>
                                                <tr>
                                                    <th>Tag</th>
                                                    <th>Digest</th>
                                                    <th>Architecture</th>
                                                    <th>OS</th>
                                                    <th>Layers</th>
                                                    <th>Size</th>
                                                    <th>Actions</th>
                                                </tr>
                                            </thead>
                                            <tbody>
                                                ${repo.tags.map(tag => `
                                                    <tr>
                                                        <td><strong>${tag.name}</strong></td>
                                                        <td><code class="digest">${this.formatDigest(tag.digest)}</code></td>
                                                        <td>${tag.architecture || 'N/A'}</td>
                                                        <td>${tag.os || 'N/A'}</td>
                                                        <td>${tag.layers || 'N/A'}</td>
                                                        <td>${this.formatBytes(tag.size)}</td>
                                                        <td>
                                                            <button class="docker-registry-mini-btn" onclick="DockerRegistryBrowser.copyPullCommand('${repo.name}', '${tag.name}')">
                                                                📋 Copy Pull Command
                                                            </button>
                                                        </td>
                                                    </tr>
                                                `).join('')}
                                            </tbody>
                                        </table>
                                    </div>
                                ` : '<p style="color:#999;padding:10px;">No tags available</p>'}
                            </div>
                        `).join('')
                    }
                </div>
            `;
        },
        
        copyPullCommand: function(repo, tag) {
            const registryHost = this.data.host + ':' + this.data.port;
            const pullCommand = `docker pull ${registryHost}/${repo}:${tag}`;
            
            // Copy to clipboard
            if (navigator.clipboard) {
                navigator.clipboard.writeText(pullCommand).then(() => {
                    alert('Copied to clipboard:\n' + pullCommand);
                }).catch(err => {
                    prompt('Copy this command:', pullCommand);
                });
            } else {
                prompt('Copy this command:', pullCommand);
            }
        },
        
        formatDigest: function(digest) {
            if (!digest) return 'N/A';
            // Show only first 12 characters of digest
            const parts = digest.split(':');
            if (parts.length === 2) {
                return parts[0] + ':' + parts[1].substring(0, 12) + '...';
            }
            return digest.length > 20 ? digest.substring(0, 20) + '...' : digest;
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
        
        showError: function(message) {
            const content = document.getElementById('docker-registry-content');
            content.innerHTML = `<p style="color:#e74c3c;padding:20px;text-align:center;">${message}</p>`;
        }
    };
})();
