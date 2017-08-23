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
import Kitura
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

public class KituraDB {

    enum DatabaseError: Error {
        case GetDatabaseFailed(String)
        case GetDocumentFailed(String)
        case GetValueFailed(String)
   	}

    let database: Database

    //for testing on Bluemix, use ConfigurationManager to get database url and credentials
    public init(cloudantConfig: CloudantService) {
        let connProperties = ConnectionProperties(host: cloudantConfig.host,
                                                  port: Int16(cloudantConfig.port),
                                                  secured: true,
                                                  username: cloudantConfig.username,
                                                  password: cloudantConfig.password)
        let couchDBClient = CouchDBClient(connectionProperties: connProperties)
        database = couchDBClient.database("trivia_questions")
        Log.info("set up database")
    }

    public func readDoc(documentID: String, callback: @escaping (JSON?, Error?) -> Void ) {
        //read document with id documentID from database
        database.retrieve(documentID) {
            document, error in
            if let error = error {
                Log.error("Error reading document \(documentID) from database")
                Log.error(error.description)
                callback(nil, error)
            } else {
                callback(document, nil)
            }
        }
    }

    public func updateDoc(documentID: String, updateDoc: JSON, rev: String, callback: @escaping (Bool, Error?) -> Void ) {
        // update document with id documentID with values updateDoc
        database.update(documentID, rev: rev, document: updateDoc) {
            rev, document, error in
            if let error = error {
                Log.error("Error updating document \(documentID) in database")
                Log.error(error.description)
                callback(false, error)
                return
            } else {
                callback (true, nil)
            }
        }
    }

    public func readQuestion(askedQuestions: Array<String>, callback: @escaping (JSON?, Error?, Array<String>?) -> Void) {
        //pick a random entry
        #if os(Linux)
            let randNum = (CGFloat(random())/CGFloat(UInt32.max))
            let coinFlip =  UInt32(random() % 2)
        #else
            let randNum = (CGFloat(arc4random())/CGFloat(UInt32.max))
            let coinFlip = arc4random_uniform(2)
        #endif
        var descend = true
        if coinFlip == 0 {
            descend = false
        }
        Log.debug("descending= " + descend.description)
        Log.debug("randNum= " + randNum.description)
        let randKey = randNum as Database.KeyType
        var updatedQuestions = askedQuestions
        database.queryByView("randSearch", ofDesign: "randList", usingParameters: [.descending(descend), .startKey([randKey])]) {
            document, error in
            if let error = error {
                //if there was an error reading, return
                Log.error("Error reading documents from database")
                Log.debug(error.description)
                callback(nil, error, nil)
            } else {
                // check that question was read
                guard let document = document else {
                    Log.error("No document returned from database")
                    callback(nil, DatabaseError.GetDocumentFailed("Failed to get document from database"), nil)
                    return
                }
                var numEntries = document["rows"].count
                var entryCount = 0
                // find a question that wasn't already asked
                while ((numEntries > 0) && askedQuestions.contains((document["rows"][entryCount]["id"].string)!)) {
                    numEntries = numEntries - 1
                    entryCount = entryCount + 1
                }
                // if we found a unasked question, return it
                if numEntries > 0 {
                    updatedQuestions.append(document["rows"][entryCount]["id"].string!)
                    callback(document["rows"][entryCount], nil, updatedQuestions)
                } else {
                    // no unasked question found, swap decending/ascending and try again
                    let fallbackQuestion = document["rows"][0]  //in case all questions were asked
                    Log.debug("descending= " + (!descend).description)
                    self.database.queryByView("randSearch", ofDesign: "randList", usingParameters: [.descending(!descend), .startKey([randKey])]) {
                        document2, error2 in
                        if let error = error2 {
                            //if there was an error reading, return
                            Log.error("Error reading documents from database")
                            Log.debug(error.description)
                            callback(nil, error, nil)
                        } else {
                            // check that question was read
                            guard let document2 = document2 else {
                                Log.error("No document returned from database")
                                callback(nil, DatabaseError.GetDocumentFailed("Failed to get document from database"), nil)
                                return
                            }
                            numEntries = document2["rows"].count
                            var entryCount = 0
                            // find a question that wasn't already asked
                            while ((numEntries > 0) && askedQuestions.contains((document2["rows"][entryCount]["id"].string)!)) {
                                numEntries = numEntries - 1
                                entryCount = entryCount + 1
                            }
                            // if we found a unasked question, return it
                            if numEntries > 0 {
                                updatedQuestions.append(document2["rows"][entryCount]["id"].string!)
                                callback(document2["rows"][entryCount], nil, updatedQuestions)
                            } else {
                                //asked all questions, reset list of asked questions
                                updatedQuestions.removeAll()
                                if document2["rows"].count > 0 {
                                    updatedQuestions.append(document2["rows"][0]["id"].string!)
                                    callback(document2["rows"][0], nil, updatedQuestions)
                                } else {
                                    updatedQuestions.append(fallbackQuestion["id"].string!)
                                    callback(fallbackQuestion, nil, updatedQuestions)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
