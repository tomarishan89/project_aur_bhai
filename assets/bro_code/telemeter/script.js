async function execute(params) {
  System.log('Telemeter v2: publishing full-sensor PWA dashboard asset...');
  const htmlAsset = (typeof System.assets !== 'undefined' && System.assets['dashboard.html']) 
    ? System.assets['dashboard.html'] 
    : (typeof System.assets !== 'undefined' && System.assets['telemeter.html']) ? System.assets['telemeter.html'] : '';
  if (!htmlAsset) {
    throw new Error('Telemeter dashboard asset missing from vaultAssets');
  }
  await System.writeVault('telemeter.html', htmlAsset, 'text/html');
  System.log('Telemeter v2: HTML published to vault (telemeter.html)');
  return 'Telemeter dashboard live. Open it from the Vault Dashboards panel.';
}
