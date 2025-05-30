// Web Cryptography Application
// Uses noble-curves for Ed25519 key operations in browsers

/**
 * Utility Module - Handles hex/byte conversions and encodings
 */
const Utils = {
  // Convert hex string to bytes
  hexToBytes(hex) {
    if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.slice(2);
    if (hex.length !== 64) return null;
    
    const bytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      const byte = hex.substr(i * 2, 2);
      if (!/^([0-9a-f]{2})$/i.test(byte)) return null;
      bytes[i] = parseInt(byte, 16);
    }
    return bytes;
  },

  // Convert bytes to hex string
  bytesToHex(arr) {
    return Array.from(arr)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  },

  // Base64 encoding for binary data
  arrayToBase64(array) {
    return btoa(String.fromCharCode.apply(null, Array.from(array)));
  },
  
  // Base64 decoding to binary data
  base64ToArray(base64) {
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  }
};

/**
 * Crypto Module - Handles cryptographic operations
 */
const Crypto = {
  async getEd25519PublicKeyFromSeed(hex) {
    if (!window.nobleCurves || !window.nobleCurves.ed25519) {
      throw new Error("nobleCurves.ed25519 not loaded");
    }
    
    if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.slice(2);
    if (!/^([0-9a-fA-F]{64})$/.test(hex)) throw new Error("Invalid hex format");
    
    const priv = Uint8Array.from(hex.match(/../g).map((b) => parseInt(b, 16)));
    return await nobleCurves.ed25519.getPublicKey(priv);
  },

  async encryptWithSharedKey(shared, userData) {
    const key = await crypto.subtle.importKey(
      "raw",
      shared.slice(0, 32), // Use first 32 bytes for key
      { name: "AES-GCM" },
      false,
      ["encrypt"]
    );
    
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      userData
    );
    
    return {
      iv: Utils.arrayToBase64(iv),
      ciphertext: Utils.arrayToBase64(new Uint8Array(ciphertext))
    };
  },

  generateRandomPrivateKey() {
    const privateKey = new Uint8Array(32);
    window.crypto.getRandomValues(privateKey);
    return privateKey;
  }
};

/**
 * API Module - Handles server communications
 */
const Api = {
  getAuthToken() {
    return document.getElementById("accessToken").value;
  },
  
  async getInfo() {
    const token = this.getAuthToken();
    try {
      const response = await fetch("/preconf/info", {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
          "Authorization": token
        }
      });
      
      if (response.status === 200) {
        return await response.json();
      } else if (response.status === 403) {
        UI.showError("Cannot fetch pubkey, token is incorrect");
        throw new Error("Bad token");
      } else {
        UI.showError("Cannot fetch pubkey, server unavailable");
        throw new Error("Cannot fetch pubkey");
      }
    } catch (error) {
      console.error("API error:", error);
      throw error;
    }
  },
  
  async setKey(data) {
    const token = this.getAuthToken();
    try {
      // Generate ephemeral key pair for key exchange
      const clientPriv = nobleCurves.x25519.utils.randomPrivateKey();
      const clientPub = nobleCurves.x25519.getPublicKey(clientPriv);
      
      // Fetch server public key (base64)
      const serverPubBase64 = await fetch("/preconf/dh", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": token
        },
        body: JSON.stringify({
          pubkey: Utils.arrayToBase64(clientPub)
        })
      }).then(r => r.text());
      
      const serverPub = Utils.base64ToArray(serverPubBase64);
      
      // Derive shared secret
      const shared = nobleCurves.x25519.getSharedSecret(clientPriv, serverPub);
      const encryptedData = await Crypto.encryptWithSharedKey(shared, data);
      
      return await fetch("/preconf/update_privkey", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": token
        },
        body: JSON.stringify(encryptedData)
      });
    } catch (error) {
      console.error("Error setting key:", error);
      throw error;
    }
  },
  
  async setInfo(hostname, role) {
    const token = this.getAuthToken();
    return await fetch("/preconf/update_hostname", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": token
      },
      body: JSON.stringify({ hostname, role })
    });
  },
  
  async setRole(roleData) {
    const token = this.getAuthToken();
    return await fetch("/preconf/set_role", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": token
      },
      body: JSON.stringify(roleData)
    });
  },
  
  async fetchDnsRecord(hostname, type) {
    const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(hostname)}&type=${type}`;
    return await fetch(url, {
      headers: { accept: "application/dns-json" }
    }).then(r => r.json());
  }
};

/**
 * UI Module - Handles DOM interactions and UI updates
 */
const UI = {
  elements: {},
  
  init() {
    // Cache DOM elements
    this.elements = {
      privateKeyInput: document.getElementById("privateKey"),
      generateKeyBtn: document.getElementById("generateKey"),
      publicKeyInput: document.getElementById("publicKey"),
      hostnameInput: document.getElementById("hostname"),
      publicKeyLabel: document.getElementById("publicKeyLabel"),
      continueBtn: document.getElementById("continueBtn"),
      continueTknBtn: document.getElementById("continueTknBtn"),
      roleSelect: document.getElementById("role"),
      keyForm: document.getElementById("keyForm"),
      joinChainForm: document.getElementById("joinChainForm"),
      newChainForm: document.getElementById("newChainForm"),
      accessToken: document.getElementById("accessToken"),
      tokenForm: document.getElementById("tokenForm"),
      logFrame: document.getElementById("logFrame")
    };
    
    // Initialize IP display element
    this.ipDisplay = document.createElement("div");
    this.ipDisplay.style.fontSize = "0.95em";
    this.ipDisplay.style.marginTop = "0.25rem";
    this.elements.hostnameInput.parentNode.appendChild(this.ipDisplay);
    
    this.setupEventListeners();
  },
  
  setupEventListeners() {
    // Private key input event
    this.elements.privateKeyInput.addEventListener("input", () => {
      this.validateAndShowPublicKey();
    });
    
    // Generate key button
    this.elements.generateKeyBtn.addEventListener("click", async () => {
      const privateKey = Crypto.generateRandomPrivateKey();
      this.elements.privateKeyInput.value = Utils.bytesToHex(privateKey);
      this.elements.continueBtn.innerHTML = "Save key and continue";
      await this.validateAndShowPublicKey();
    });
    
    // Continue button
    this.elements.continueBtn.addEventListener("click", async () => {
      try {
        if (this.elements.privateKeyInput.value.trim()) {
          const valid = await this.validateAndShowPublicKey();
          if (!valid) return;
          
          let hex = this.elements.privateKeyInput.value.trim();
          if (!hex.startsWith("0x")) hex = "0x" + hex;
          
          const bytes = Utils.hexToBytes(hex);
          const response = await Api.setKey(bytes);
          
          if (!response.ok) {
            this.showError("Failed to save private key");
            return;
          }
        }
        
        const info = await Api.getInfo();
        await Api.setInfo(this.elements.hostnameInput.value, this.elements.roleSelect.value);
        
        if (this.elements.publicKeyInput.value != info.pubkey) {
          this.showError("Public key does not match");
          return;
        }
        
        this.elements.keyForm.classList.add("d-none");
        this.showRoleForm(this.elements.roleSelect.value);
      } catch (error) {
        console.error("Error in continue flow:", error);
        this.showError("An error occurred. Please try again.");
      }
    });
    
    // Continue token button
    this.elements.continueTknBtn.addEventListener("click", async () => {
      this.loadInfo();
    });
    
    // Role select change
    this.elements.roleSelect.addEventListener("change", () => {
      if (this.elements.keyForm.classList.contains("d-none")) {
        this.showRoleForm(this.elements.roleSelect.value);
      }
    });
    
    // Hostname input events
    let resolveTimeout;
    this.elements.hostnameInput.addEventListener("input", () => {
      clearTimeout(resolveTimeout);
      this.elements.hostnameInput.style.background = "";
      this.ipDisplay.textContent = "";
      
      this.elements.continueBtn.disabled = true;
      if (!this.elements.hostnameInput.value.trim()) return;
      resolveTimeout = setTimeout(() => this.resolveHost(), 600);
    });
  },
  
  async validateAndShowPublicKey() {
    const hex = this.elements.privateKeyInput.value.trim();
    const bytes = Utils.hexToBytes(hex);
    
    if (!bytes) {
      this.elements.publicKeyLabel.textContent = "Incorrect private key";
      this.elements.publicKeyLabel.style.color = "red";
      this.elements.publicKeyInput.value = "";
      return false;
    }
    
    try {
      const pub = await Crypto.getEd25519PublicKeyFromSeed(hex);
      this.elements.publicKeyInput.value = "0x" + Utils.bytesToHex(pub);
      this.elements.publicKeyLabel.textContent = "Public key";
      this.elements.publicKeyLabel.style.color = "";
      return true;
    } catch (e) {
      this.elements.publicKeyLabel.textContent = "Incorrect private key";
      this.elements.publicKeyLabel.style.color = "red";
      this.elements.publicKeyInput.value = "";
      return false;
    }
  },
  
  showRoleForm(role) {
    // Hide all forms first
    this.elements.newChainForm.classList.add("d-none");
    this.elements.joinChainForm.classList.add("d-none");
    
    if (role === "new_chain") {
      this.elements.newChainForm.classList.remove("d-none");
    } else {
      this.elements.joinChainForm.classList.remove("d-none");
    }
    
    this.setupRoleForm(role);
  },
  
  setupRoleForm(role) {
    if (role === "new_chain") {
      document.getElementById("nextRole").onclick = async () => {
        const nodeName = document.getElementById("nodeName").value.trim();
        const ceremonyToken = document.getElementById("ceremonyToken").value.trim();
        
        if (!nodeName || !ceremonyToken) {
          this.showError("All fields required.");
          return;
        }
        
        try {
          const response = await Api.setRole({
            role: "tea",
            nodeName: nodeName,
            ceremonyToken: ceremonyToken
          });
          
          if (!response.ok) {
            this.showError("Failed to save role data");
          } else {
            this.showSuccess("Configuration saved.");
          }
        } catch (error) {
          console.error("Error setting role:", error);
          this.showError("Failed to save role data");
        }
      };
    } else {
      const urlGroup = document.getElementById("urlGroup");
      
      // Set up dynamic URL inputs
      urlGroup.addEventListener("click", (e) => {
        if (e.target.classList.contains("add-url")) {
          const newInput = document.createElement("div");
          newInput.className = "input-group mb-2";
          newInput.innerHTML = `
            <input type="text" class="form-control url-input" placeholder="http://node.domain/">
            <button type="button" class="btn btn-outline-danger remove-url">-</button>
          `;
          urlGroup.appendChild(newInput);
        } else if (e.target.classList.contains("remove-url")) {
          e.target.parentElement.remove();
        }
      });
      
      document.getElementById("nextRole").onclick = async () => {
        const urls = Array.from(document.querySelectorAll(".url-input"))
          .map(input => input.value.trim())
          .filter(Boolean);
          
        if (urls.length === 0) {
          this.showError("Enter at least one URL.");
          return;
        }
        
        const roleKey = role === "join_member" ? "member" : "replica";
        
        try {
          const response = await Api.setRole({
            role: roleKey,
            peerUrls: urls,
            nodeName: ""
          });
          
          if (!response.ok) {
            this.showError("Failed to save role data");
          } else {
            this.showSuccess("Configuration saved.");
          }
        } catch (error) {
          console.error("Error setting role:", error);
          this.showError("Failed to save role data");
        }
      };
    }
  },
  
  async loadInfo() {
    try {
      const info = await Api.getInfo();
      
      this.elements.tokenForm.style.display = "none";
      this.elements.keyForm.style.display = "";
      this.elements.publicKeyInput.value = info.pubkey;
      
      if (this.elements.hostnameInput.value != info.hostname) {
        this.elements.hostnameInput.value = info.hostname;
        this.resolveHost();
      }
      
      LogMonitor.start();
    } catch (error) {
      console.error("Error loading info:", error);
      this.showError("Failed to load information");
    }
  },
  
  async resolveHost() {
    const hostname = this.elements.hostnameInput.value.trim();
    if (!hostname) return;
    
    try {
      // Try to resolve IPv4
      const data = await Api.fetchDnsRecord(hostname, "A");
      
      // Find first A record in any answer
      let ip = "";
      if (data.Answer) {
        for (const ans of data.Answer) {
          if (ans.type === 1 && /^[0-9.]+$/.test(ans.data)) {
            ip = ans.data;
            break;
          }
        }
      }
      
      if (ip) {
        this.elements.continueBtn.disabled = false;
        this.elements.hostnameInput.style.background = "#cfc";
        this.ipDisplay.textContent = `Resolved IPv4: ${ip}`;
        
        try {
          // Try to resolve IPv6
          const dataAAAA = await Api.fetchDnsRecord(hostname, "AAAA");
          if (dataAAAA.Answer) {
            for (const ans of dataAAAA.Answer) {
              // type 28 = AAAA
              if (ans.type === 28 && /^[a-fA-F0-9:]+$/.test(ans.data)) {
                const ipv6 = ans.data;
                this.ipDisplay.textContent = `Resolved IPv4: ${ip}, IPv6: ${ipv6}`;
                break;
              }
            }
          }
        } catch {
          this.ipDisplay.textContent = `Resolved IPv4: ${ip}, no IPv6`;
        }
      } else {
        this.elements.hostnameInput.style.background = "#fcc";
        this.ipDisplay.textContent = "Hostname not resolved";
        this.elements.continueBtn.disabled = true;
      }
    } catch (e) {
      this.elements.hostnameInput.style.background = "#fcc";
      this.ipDisplay.textContent = "Hostname not resolved";
      this.elements.continueBtn.disabled = true;
    }
  },
  
  showError(message) {
    alert(message);
  },
  
  showSuccess(message) {
    alert(message);
  }
};

/**
 * LogMonitor Module - Handles progress logging
 */
const LogMonitor = {
  timestamp: 0,
  running: false,
  retryDelay: 1000,
  retryMax: 600000, // 10 minutes max
  
  start() {
    if (this.running || !Api.getAuthToken()) return;
    this.running = true;
    this.pollLogs();
  },
  
  async pollLogs() {
    try {
      const response = await fetch(`/preconf/tea_progress/${this.timestamp}`, {
        headers: { authorization: Api.getAuthToken() }
      });
      
      if (response.status === 403) {
        this.running = false;
        Toastify({
          text: "Token expired or invalid",
          duration: 4000,
          gravity: "top",
          position: "right",
          backgroundColor: "orange"
        }).showToast();
        return;
      }
      
      const data = await response.json();
      if (data.ok && data.data) {
        data.data.forEach(line => this.appendLog(line));
        this.retryDelay = 1000; // Reset delay on success
        this.timestamp = data.t;
      }
    } catch (err) {
      this.retryDelay = Math.min(this.retryDelay * 2, this.retryMax);
      // Ignore error, keep polling with same timestamp
    } finally {
      if (this.running) {
        setTimeout(() => this.pollLogs(), this.retryDelay);
      }
    }
  },
  
  appendLog(message) {
    const logFrame = document.getElementById("logFrame");
    if (!logFrame) return;
    
    const line = document.createElement("div");
    if (typeof message === "object") {
      line.textContent = JSON.stringify(message, null, 2);
    } else {
      line.textContent = message;
    }
    
    logFrame.appendChild(line);
    logFrame.scrollTop = logFrame.scrollHeight;
  }
};

// Initialize the application when the DOM is fully loaded
document.addEventListener("DOMContentLoaded", () => {
  UI.init();
});
