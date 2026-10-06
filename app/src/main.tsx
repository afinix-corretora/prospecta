import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
// As fontes vêm com o build, não do Google: o app não depende de um terceiro
// para ter a própria cara, e a primeira pintura já sai na letra certa.
import '@fontsource-variable/anek-latin/standard.css';
import '@fontsource-variable/roboto';
import '@fontsource-variable/roboto-mono';
import { App } from './App';
import './estilo.css';

const raiz = document.getElementById('raiz');
if (!raiz) throw new Error('#raiz não existe no index.html');

createRoot(raiz).render(<StrictMode><App /></StrictMode>);
