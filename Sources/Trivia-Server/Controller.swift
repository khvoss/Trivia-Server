/**
 * Copyright 2017 International Business Machines Corporation ("IBM")
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation
import Dispatch
import Kitura
import KituraSession
import SwiftyJSON
import LoggerAPI
import Configuration
import CloudFoundryEnv
import CloudFoundryConfig
import CouchDB
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public class Controller {

    let router: Router
    let session: Session
    var sess: SessionState?
    let configMgr: ConfigurationManager
    let kituradb: KituraDB

    var port: Int {
        get { return configMgr.port }
    }

    var url: String {
        get { return configMgr.url }
    }

    init() throws {
        configMgr = ConfigurationManager()
        configMgr.load(file: "../../cloud_config.json")
        configMgr.load(.environmentVariables)
        let cloudantConfig = try configMgr.getCloudantService(name: "Cloudant NoSQL DB-4u") //replace "Cloudant NoSQL DB" with name of your database
        kituradb = KituraDB(cloudantConfig: cloudantConfig)

        // All web apps need a Router instance to define routes
        router = Router()

        // Initialising our KituraSession - use your own secret
        session = Session(secret: "temp_secret")

        // Use session in all routes
        router.all(middleware: session)

        // Use BodyParser in all routes
        router.all(middleware: BodyParser())

        // GET request with question database read
        router.get("/getquestion", handler: getQuestion)
        router.get("/getquestion/:language", handler: getQuestion)

        // GET request with multiple question database reads
        router.get("/getquestions", handler: getQuestions)
        router.get("/getquestions/:language", handler: getQuestions)

        // POST request with database write
        router.post("/answer", handler: postAnswer)
    }

    /**
     * Handler for reading a question from the database
     */
    public func getQuestion(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.debug("GET - /getquestion route handler...")
        // get list of already asked questions from session
        var askedQuestions: Array<String> = [String]()
        sess = request.session
        if !(sess?["askedQuestions"].isEmpty)! {
            askedQuestions = sess?["askedQuestions"].arrayObject as! Array<String>
        }
        //if language was set, get questions in that language
        let supportedLanguages = ["EN", "ES", ""]
        var language = request.parameters["language"] ?? "" //EN default
        if (!supportedLanguages.contains(language) || language == "EN") {
            language = ""  //specified unavailable languageor EN, use EN
        }
        //read a new question for the database
        kituradb.readQuestion(askedQuestions: askedQuestions) {
            json, error, list in
            do {
                // check that a question was returned
                guard let json = json else {
                    Log.warning("Could not read a question from the database")
                    response.status(.badRequest)
                    return
                }
                let values = json["value"]
                //update askedQuestions list
                self.sess?["askedQuestions"] = JSON(list!)
                //format question data to return to caller
                let sendJSON = JSON(self.setupResponse(inJSON: values, language: language))

                // send response
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                try response.status(.OK).send(json: sendJSON).end()
            } catch {
                Log.error("Error getting document from KituraDB")
                response.status(.badRequest)
            }
        }
    }

    /**
     * Handler for reading multiple questions from the database
     */
    public func getQuestions(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.debug("GET - /getquestions route handler...")
        var numQuestions = 5
        var sendArray: [Any] = []
        var tempArray: [String : Any] = [:]

        // get list of already asked questions from session
        var askedQuestions: Array<String> = [String]()
        sess = request.session
        if !(sess?["askedQuestions"].isEmpty)! {
            askedQuestions = sess?["askedQuestions"].arrayObject as! Array<String>
        }

        //if language was set get questions in that language
        let supportedLanguages = ["EN", "ES", ""]
        var language = request.parameters["language"] ?? "" //EN default
        if (!supportedLanguages.contains(language) || language == "EN") {
            language = ""  //specified unavailable language or EN, use EN
        }

        //query one question at a time to avoid duplicates
        let semaphore = DispatchSemaphore(value: 0)
        var timeout = DispatchTime.now()

        while (numQuestions > 0) {
            //read a new question for the database
            kituradb.readQuestion(askedQuestions: askedQuestions) {
                json, error, list in
                do {
                    // check that a question was returned
                    guard let json = json else {
                        Log.warning("Could not read a question from the database")
                        semaphore.signal()
                        return
                    }

                    let values = json["value"]
                    //update askedQuestions list
                    askedQuestions = list!
                    //format question data to return
                    tempArray = self.setupResponse(inJSON: values, language: language)
                    //add question to question array to return
                    sendArray.append(tempArray)
                    semaphore.signal()
                }
            }
            timeout = DispatchTime.now() + .seconds(1)
            //need to run query one at a time to prevent duplicates
            if semaphore.wait(timeout: timeout) == .timedOut {
                print("request timed out")
            }
            numQuestions = numQuestions - 1
        }
        //prepare questions to send
        let sendJSON = JSON(sendArray)
        if !sendJSON.isEmpty {
            //update askedQuestions list
            self.sess?["askedQuestions"] = JSON(askedQuestions)
            // send response
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            try response.status(.OK).send(json: sendJSON).end()
        } else {
            Log.error("Could not read questions from database")
            response.status(.badRequest)
        }
    }

    func setupResponse(inJSON: JSON, language: String) -> [String : Any] {
        var choices = Array(repeating: " ", count: 4)

        func randomize(_a1: String, _a2: String) -> Bool {
            #if os(Linux)
                return random() > random()
            #else
                return arc4random() > arc4random()
            #endif
        }

        // get question identifier
        let id = inJSON["_id"].string ?? ""
        // get question text
        let question = inJSON["question".appending(language)].string ?? "Question not found"
        // get correct answer
        let correctAnswer = inJSON["correctAnswer".appending(language)].string ?? " "
        // get choices text
        choices[0] = inJSON["correctAnswer".appending(language)].string ?? " "
        choices[1] = inJSON["incorrectAnswers".appending(language)][0].string ?? " "
        choices[2] = inJSON["incorrectAnswers".appending(language)][1].string ?? " "
        choices[3] = inJSON["incorrectAnswers".appending(language)][2].string ?? " "

        // shuffle choices
        var randChoices = choices.sorted(by:randomize)
        choices = randChoices.sorted(by:randomize)
        randChoices = choices.sorted(by:randomize)

        // get times question answered for dificulty calculation
        let timesAttempted = inJSON["timesAttempted"].int ?? 0
        // get times question answered correctly for dificulty calculation
        let timesCorrect = inJSON["timesCorrect"].int ?? 0

        // create array to return to caller
        let sendArray = ["question": question, "answer1": randChoices[0], "answer2": randChoices[1],
                         "answer3": randChoices[2], "answer4": randChoices[3], "id": id, "correct": correctAnswer,
                         "timesCorrect": timesCorrect, "timesAttempted": timesAttempted] as [String : Any]
        return sendArray
    }

    /**
     * Handler for writing results to the database
     */
    public func postAnswer(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.debug("POST - /answer route handler...")
        // read POST request body
        if let parsedBody = request.body?.asJSON {
            guard let question = parsedBody["question"].string else {
                Log.error("bad POST request to /answer, no question id")
                response.status(.badRequest)
                return
            }
            guard let correct = parsedBody["correct"].bool else {
                Log.error("bad POST request to /answer, no correct boolean")
                response.status(.badRequest)
                return
            }
            // re-fetch question from database
            kituradb.readDoc(documentID: question) {
                json, error in
                do {
                    guard var json = json else {
                        Log.error("Couldn't read document from database")
                        response.status(.badRequest)
                        return
                    }
                    guard var timesAttempted = json["timesAttempted"].int else {
                        Log.error("Couldn't get attempted count")
                        response.status(.badRequest)
                        return
                    }
                    guard var timesCorrect = json["timesCorrect"].int else {
                        Log.error("Couldn't get correct count")
                        response.status(.badRequest)
                        return
                    }
                    guard let rev = json["_rev"].string else {
                        Log.error("Couldn't get rev")
                        response.status(.badRequest)
                        return
                    }
                    //update attempted and correct counts
                    timesAttempted = timesAttempted+1
                    if (correct) {
                        timesCorrect = timesCorrect+1
                    }
                    json["timesAttempted"] = JSON(timesAttempted)
                    json["timesCorrect"] = JSON(timesCorrect)
                    // push updated counts to database
                    self.kituradb.updateDoc(documentID: question, updateDoc: json, rev: rev) {
                        success, error in
                        do {
                            if (success) {
                                response.headers["Content-Type"] = "text/plain; charset=utf-8"
                                try response.status(.OK).send("Question \(question) updated").end()
                            } else {
                                Log.error("Failed to update doc")
                                response.status(.badRequest)
                            }
                        } catch {
                            Log.error("Failed to call update doc")
                            response.status(.badRequest)
                        }
                    }
                }
            }

        } else {
            Log.error("Couldn't read POST to /answer")
            response.status(.badRequest)
        }
    }
}
