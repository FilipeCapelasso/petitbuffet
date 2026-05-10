'use strict';

const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs').promises;
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  maxHttpBufferSize: 10 * 1024 * 1024,
  cors: { origin: process.env.CORS_ORIGIN || '*' }
});

const PORT = Number(process.env.PORT || 3000);
const ADMIN_PASS = process.env.ADMIN_PASS || 'MUDAR_ISTO_123';

const STOCK_PATH = path.join(__dirname, 'stock-state.json');
const PRICE_PATH = path.join(__dirname, 'price-state.json');
const ORDERS_PATH = path.join(__dirname, 'orders-state.json');

app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true, limit: '2mb' }));
app.use(express.static(__dirname));
app.use('/adm', express.static(path.join(__dirname, '..', 'adm')));

async function loadJSON(filePath, fallback) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

async function saveJSON(filePath, data) {
  const tmp = `${filePath}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2), 'utf8');
  await fs.rename(tmp, filePath);
}

function normalizePedido(order = {}) {
  const pedido = String(order.pedido || order.order_id || order.id || '').trim();
  return { ...order, pedido, order_id: pedido, id: pedido };
}

function onlyDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function validateOrder(order) {
  const normalized = normalizePedido(order);
  const errors = [];
  if (!normalized.pedido) errors.push('pedido ausente');
  if (!String(normalized.nome || '').trim()) errors.push('nome ausente');
  if (onlyDigits(normalized.telefone).length < 10) errors.push('telefone inválido');
  if (!String(normalized.endereco || '').trim()) errors.push('endereço ausente');
  if (!String(normalized.itens || '').trim()) errors.push('itens ausentes');
  if (Number(normalized.total) <= 0 || Number.isNaN(Number(normalized.total))) errors.push('total inválido');
  return { ok: errors.length === 0, errors, order: normalized };
}

let estadoEstoque = {};
let estadoPrecos = {};
let pedidosPendentes = [];
let ready = false;

async function bootstrap() {
  estadoEstoque = await loadJSON(STOCK_PATH, {});
  estadoPrecos = await loadJSON(PRICE_PATH, {});
  pedidosPendentes = await loadJSON(ORDERS_PATH, []);
  ready = true;
}

app.get('/api/health', (_req, res) => {
  res.json({ ok: true, ready, service: 'Petit Buffet Premium', socket: true });
});

app.get('/api/state', (_req, res) => {
  res.json({ ok: true, stock: estadoEstoque, prices: estadoPrecos });
});

io.on('connection', (socket) => {
  const role = String(socket.handshake.query.role || 'client');
  const token = String(socket.handshake.query.token || '');

  if (role === 'admin' && token !== ADMIN_PASS) {
    socket.emit('auth-error', { ok: false, error: 'Senha administrativa inválida.' });
    socket.disconnect(true);
    return;
  }

  const room = role === 'admin' ? 'admins' : 'clients';
  socket.join(room);

  socket.emit('stock-state-sync', estadoEstoque);
  socket.emit('price-state-sync', estadoPrecos);
  if (room === 'admins') socket.emit('admin-orders-sync', pedidosPendentes);

  socket.on('admin-update-product', async (data = {}, ack) => {
    try {
      if (role !== 'admin') throw new Error('Acesso negado.');
      const id = String(data.id || '').trim();
      if (!id) throw new Error('Produto inválido.');
      estadoEstoque[id] = data.status === 'disponivel' || data.disponivel === true;
      await saveJSON(STOCK_PATH, estadoEstoque);
      io.emit('stock-state-sync', estadoEstoque);
      io.to('clients').emit('client-update-stock', { id, disponivel: estadoEstoque[id] });
      if (typeof ack === 'function') ack({ ok: true });
    } catch (error) {
      if (typeof ack === 'function') ack({ ok: false, error: error.message });
    }
  });

  socket.on('admin-update-price', async (data = {}, ack) => {
    try {
      if (role !== 'admin') throw new Error('Acesso negado.');
      const id = String(data.id || '').trim();
      const value = Number(data.valorNum ?? data.price ?? data.valor);
      if (!id || Number.isNaN(value) || value < 0) throw new Error('Preço inválido.');
      estadoPrecos[id] = value;
      await saveJSON(PRICE_PATH, estadoPrecos);
      io.emit('price-state-sync', estadoPrecos);
      if (typeof ack === 'function') ack({ ok: true });
    } catch (error) {
      if (typeof ack === 'function') ack({ ok: false, error: error.message });
    }
  });

  socket.on('client-new-order', async (rawOrder = {}, ack) => {
    try {
      const validation = validateOrder(rawOrder);
      if (!validation.ok) throw new Error(validation.errors.join(', '));
      const order = { ...validation.order, received_at: new Date().toISOString() };
      const idx = pedidosPendentes.findIndex((item) => normalizePedido(item).pedido === order.pedido);
      if (idx >= 0) pedidosPendentes[idx] = { ...pedidosPendentes[idx], ...order };
      else pedidosPendentes.unshift(order);
      pedidosPendentes = pedidosPendentes.slice(0, 500);
      await saveJSON(ORDERS_PATH, pedidosPendentes);
      io.to('admins').emit('new-order-to-admin', order);
      io.to('admins').emit('admin-orders-sync', pedidosPendentes);
      if (typeof ack === 'function') ack({ ok: true, pedido: order.pedido });
    } catch (error) {
      if (typeof ack === 'function') ack({ ok: false, error: error.message });
    }
  });
});

bootstrap()
  .then(() => server.listen(PORT, () => console.log(`Servidor Petit Buffet rodando na porta ${PORT}`)))
  .catch((error) => {
    console.error('Falha ao iniciar servidor:', error);
    process.exit(1);
  });
