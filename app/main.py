from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
import os
from mangum import Mangum

app = FastAPI(
    title="Sample FastAPI Application",
    description="A sample FastAPI application deployed on AWS Lambda",
    version="1.0.0"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
@app.get("/test")
def getTestDetails():
    return "You have reached GetTestdetails method"

handler = Mangum(app)