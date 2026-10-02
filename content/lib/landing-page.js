'use strict'

module.exports.register = function () {
  this.once('beforePublish', ({ contentCatalog, uiCatalog }) => {
    if (!uiCatalog.getFiles().some((file) => file.out && file.out.path === 'index.html')) return
    contentCatalog
      .findBy({ family: 'alias' })
      .forEach((file) => {
        if (file.out && file.out.path === 'index.html') delete file.out
      })
  })
}
