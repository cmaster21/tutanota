// @flow
import {Dialog} from "../gui/base/Dialog"
import {worker} from "../api/main/WorkerClient"
import {createDataFile} from "../api/common/DataFile"
import {assertMainOrNode, isAndroidApp} from "../api/Env"
import {fileApp} from "../native/FileApp"
import {neverNull} from "../api/common/utils/Utils"
import {showProgressDialog} from "../gui/base/ProgressDialog"
import {CryptoError} from "../api/common/error/CryptoError"
import {lang} from "../misc/LanguageViewModel"

assertMainOrNode()

export class FileController {

	downloadAndOpen(tutanotaFile: TutanotaFile): Promise<void> {
		return showProgressDialog("pleaseWait_msg",
			worker.downloadFileContent(tutanotaFile).then(file => {
				if (!isAndroidApp()) { // on android we store files in the download folder
					return this.open(file)
				}
			}).catch(err => {
				if (err instanceof CryptoError) {
					return Dialog.error("corrupted_msg")
				} else {
					return Dialog.error("couldNotAttachFile_msg")
				}
			})
		)
	}

	downloadAndOpenAll(tutanotaFiles: TutanotaFile[]): Promise<void> {
		return showProgressDialog("pleaseWait_msg",
			(isAndroidApp() ? Promise.each : Promise.map)(tutanotaFiles, (tutanotaFile) => {
				return worker.downloadFileContent(tutanotaFile)
				             .catch(err => {
					             if (err instanceof CryptoError) {
						             return Dialog.error(() => lang.get("corrupted_msg") + " " + tutanotaFile.name)
					             } else {
						             return Dialog.error(() => lang.get("couldNotAttachFile_msg") + " "
							             + tutanotaFile.name)
					             }
				             })
			}).each((file, index) => {
				if (!isAndroidApp()) {
					return fileController.open(file)
				}
			})
		).return()
	}

	/**
	 * @param allowedExtensions Array of extensions strings without "."
	 */
	showFileChooser(multiple: boolean, allowedExtensions: ?string[]): Promise<Array<DataFile>> {
		// if (tutao.tutanota.util.ClientDetector.getDeviceType() == tutao.tutanota.util.ClientDetector.DEVICE_TYPE_WINDOWS_PHONE) {
		// 	return tutao.tutanota.gui.alert(tutao.lang("addAttachmentNotPossibleIe_msg")).then(function() {
		// 		return []
		// 	})
		// }
		// each time when called create a new file chooser to make sure that the same file can be selected twice directly after another
		// remove the last file input

		const fileInput = document.getElementById("hiddenFileChooser");
		const body = neverNull(document.body)
		if (fileInput) {
			// remove the old one because it may contain a file already
			body.removeChild(fileInput)
		}

		const newFileInput = document.createElement("input")
		newFileInput.setAttribute("type", "file")
		if (multiple) {
			newFileInput.setAttribute("multiple", "multiple")
		}
		newFileInput.setAttribute("id", "hiddenFileChooser")
		if (allowedExtensions) {
			newFileInput.setAttribute("accept", allowedExtensions.map(e => "." + e).join(","))
		}
		newFileInput.style.display = "none"

		let promise = Promise.fromCallback(cb => {
			newFileInput.addEventListener("change", e => {
				this.readLocalFiles((e.target: any).files).then(dataFiles => {
					cb(null, dataFiles)
				}).catch(e => {
					console.log(e)
					return Dialog.error("couldNotAttachFile_msg").then(() => {
						cb(null, [])
					})
				})
			})
		})

		// the file input must be put into the dom, otherwise it does not work in IE
		body.appendChild(newFileInput)
		newFileInput.click()

		return promise
	}

	readLocalFiles(fileList: FileList): Promise<DataFile[]> {
		// create an array of files form the FileList because we can not iterate the FileList directly
		let nativeFiles = []
		for (let i = 0; i < fileList.length; i++) {
			nativeFiles.push(fileList[i])
		}
		return Promise.map(nativeFiles, nativeFile => {
			return Promise.fromCallback(cb => {
				let reader = new FileReader()
				reader.onloadend = function (evt) {
					if (evt.target.readyState === (FileReader: any).DONE && evt.target.result) { // DONE == 2
						cb(null, createDataFile(nativeFile, new Uint8Array(evt.target.result)))
					} else {
						cb(new Error("could not load file"), null)
					}
				}
				reader.readAsArrayBuffer(nativeFile)
			})
		})
	}

	open(file: DataFile | FileReference): Promise<void> {
		if (file._type === 'FileReference') {
			let fileReference = ((file: any): FileReference)
			return fileApp.open(fileReference)
		} else {
			let dataFile = ((file: any): DataFile)
			let saveFunction: Function = window.saveAs || window.webkitSaveAs || window.mozSaveAs || window.msSaveAs
				|| (navigator: any).saveBlob || (navigator: any).msSaveOrOpenBlob || (navigator: any).msSaveBlob
				|| (navigator: any).mozSaveBlob || (navigator: any).webkitSaveBlob
			if (saveFunction) {
				let blob = new Blob([dataFile.data], {"type": dataFile.mimeType})
				try {
					// in IE the save function must be called directly, otherwise an error is thrown
					if (navigator.msSaveOrOpenBlob) {
						(navigator: any).msSaveOrOpenBlob(blob, dataFile.name)
					} else if (navigator.msSaveBlob) {
						(navigator: any).msSaveBlob(blob, dataFile.name)
					} else {
						saveFunction(blob, dataFile.name)
					}
					return Promise.resolve()
				} catch (e) {
					console.log(e)
					return Dialog.error("saveDownloadNotPossibleIe_msg")
				}
			} else {
				try {
					let URL = window.URL || window.webkitURL || window.mozURL || window.msURL
					let blob = new Blob([dataFile.data], {type: dataFile.mimeType})
					let url = URL.createObjectURL(blob)
					let a = document.createElement("a")
					if (typeof a.download !== "undefined") {
						a.href = url
						a.download = dataFile.name
						a.style.display = "none"
						const body = neverNull(document.body)
						body.appendChild(a)
						a.click()
						body.removeChild(a)
						window.URL.revokeObjectURL(url)
					} else {
						// if the download attribute is not supported try to open the link in a new tab.
						return Dialog.legacyDownload(dataFile.name, url)
					}
					return Promise.resolve()
				} catch (e) {
					console.log(e)
					return Dialog.error("canNotOpenFileOnDevice_msg")
				}
				// let url
				// FIXME: test in Safari mobile and android
				// android browser and safari mobile < v7 can not open blob urls. unfortunately we can not generally check if this is supported, so we need to check the browser type
				// if ((tutao.tutanota.util.ClientDetector.getBrowserType() == tutao.tutanota.util.ClientDetector.BROWSER_TYPE_SAFARI && tutao.tutanota.util.ClientDetector.isMobileDevice() && tutao.tutanota.util.ClientDetector.getBrowserVersion() < 7)) {
				// 	let base64 = tutao.util.EncodingConverter.bytesToBase64(new Uint8Array(dataFile.getData()))
				// 	url = "data:" + mimeType + ";base64," + base64
				// } else {
				// let blob = new Blob([fileContent], {"type": mimeType})
				// url = URL.createObjectURL(blob)
				// }
				// firefox on android, safari on OS X and >= v7 on iOS do not support opening links with simulated clicks, so show a download dialog. Safari < v7 and Android browser may only open some file types in the browser, so we show the dialog to display the info text
				// FIXME test attachments
				// if (tutao.tutanota.util.ClientDetector.getBrowserType() == tutao.tutanota.util.ClientDetector.BROWSER_TYPE_SAFARI) {
				// 	let textId = 'saveDownloadNotPossibleSafariDesktop_msg'
				// 	if (tutao.tutanota.util.ClientDetector.isMobileDevice()) {
				// 		textId = 'saveDownloadNotPossibleSafariMobile_msg'
				// 	}
				// 	return tutao.locator.legacyDownloadViewModel.showDialog(dataFile.getName(), url, textId).then(function () {
				// 		// the blob must be deleted after usage. delete it after 1 ms in case some save operation is done async
				// 		setTimeout(function () {
				// 			URL.revokeObjectURL(url)
				// 		}, 1)
				// 	})
				// } else {
				// 	fileSaverSaveAs(new Blob([dataFile.getData()], {type: mimeType}), dataFile.getName())

				// return Promise.resolve()
				// }
			}
		}
	}
}

export const fileController: FileController = new FileController()


